const std = @import("std");
const gooey = @import("gooey");

// Layout imports
const layout = gooey.layout;
const LayoutEngine = layout.LayoutEngine;
const LayoutId = layout.LayoutId;
const Sizing = layout.Sizing;
const SizingAxis = layout.SizingAxis;
const Padding = layout.Padding;
const Color = layout.Color;
const CornerRadius = layout.CornerRadius;
const ChildAlignment = layout.ChildAlignment;
const RenderCommandType = layout.RenderCommandType;

// Core gooey types
const Scene = gooey.Scene;
const Hsla = gooey.Hsla;
const Quad = gooey.Quad;
const Shadow = gooey.Shadow;
const TextInput = gooey.TextInput;
const ViewTree = gooey.ViewTree;

// Reactive types
const ViewContext = gooey.ViewContext;
const RenderOutput = gooey.RenderOutput;
const Context = gooey.Context;
const Entity = gooey.Entity;

// =============================================================================
// Application State (Reactive Entity)
// =============================================================================

const AppState = struct {
    // Form state
    username: []const u8,
    password: []const u8,

    // UI state
    login_attempts: i32,
    is_submitting: bool,
    error_message: ?[]const u8,

    // Focus tracking
    focused_field: FocusedField,

    const FocusedField = enum {
        none,
        username,
        password,
    };

    // This makes AppState "Renderable" - it can be a window's root view
    pub fn render(self: *AppState, cx: *ViewContext(AppState)) RenderOutput {
        _ = cx;
        std.debug.print("Rendering AppState: attempts={}, submitting={}\n", .{ self.login_attempts, self.is_submitting });
        return RenderOutput.withContent();
    }

    // Actions that modify state
    pub fn setUsername(self: *AppState, cx: *ViewContext(AppState), value: []const u8) void {
        self.username = value;
        cx.notify();
    }

    pub fn setPassword(self: *AppState, cx: *ViewContext(AppState), value: []const u8) void {
        self.password = value;
        cx.notify();
    }

    pub fn submit(self: *AppState, cx: *ViewContext(AppState)) void {
        self.login_attempts += 1;
        self.is_submitting = true;

        // Simulate validation
        if (self.username.len == 0) {
            self.error_message = "Username is required";
            self.is_submitting = false;
        } else if (self.password.len == 0) {
            self.error_message = "Password is required";
            self.is_submitting = false;
        } else {
            self.error_message = null;
            std.debug.print("Login attempt #{}: user={s}\n", .{ self.login_attempts, self.username });
        }

        cx.notify();
    }

    pub fn focusNext(self: *AppState, cx: *ViewContext(AppState)) void {
        self.focused_field = switch (self.focused_field) {
            .none, .password => .username,
            .username => .password,
        };
        cx.notify();
    }

    pub fn cancel(self: *AppState, cx: *ViewContext(AppState)) void {
        self.username = "";
        self.password = "";
        self.error_message = null;
        self.focused_field = .username;
        cx.notify();
    }
};

// =============================================================================
// Rendering Context (holds non-reactive resources)
// =============================================================================

const RenderContext = struct {
    allocator: std.mem.Allocator,
    text_system: *gooey.TextSystem,
    layout_engine: *LayoutEngine,
    scene: *Scene,
    username_input: *TextInput,
    password_input: *TextInput,
    view_tree: *ViewTree,
    scale_factor: f32,
    window_width: f32,
    window_height: f32,
};

// Global render context (needed for callbacks)
var g_render_ctx: ?*RenderContext = null;
var g_app: ?*gooey.App = null;
var g_app_state: ?Entity(AppState) = null;
var g_building_scene: bool = false; // Guard against re-entrant builds

// =============================================================================
// Main
// =============================================================================

pub fn main() !void {
    std.debug.print("Starting gooey with reactive state...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize app
    var app = try gooey.App.init(allocator);
    defer app.deinit();
    g_app = &app;

    // Create window
    var window = try app.createWindow(.{
        .title = "gooey - Reactive Login Form",
        .width = 800,
        .height = 600,
        .background_color = gooey.Color.init(0.95, 0.95, 0.95, 1.0),
    });
    defer window.deinit();

    // Connect window to app for reactive rendering
    app.connectWindow(window);

    // Initialize text system
    var text_system = try gooey.TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
    defer text_system.deinit();
    try text_system.loadFont("Menlo", 16.0);

    // Initialize layout engine
    var layout_engine = LayoutEngine.init(allocator);
    defer layout_engine.deinit();
    layout_engine.setMeasureTextFn(measureTextCallback, &text_system);

    // Create text inputs
    var username_input = TextInput.init(allocator, .{ .x = 0, .y = 0, .width = 300, .height = 36 });
    defer username_input.deinit();
    username_input.setPlaceholder("Username");

    var password_input = TextInput.init(allocator, .{ .x = 0, .y = 0, .width = 300, .height = 36 });
    defer password_input.deinit();
    password_input.setPlaceholder("Password");

    // Build view tree for focus management
    var view_tree = ViewTree.init(allocator);
    defer view_tree.deinit();
    try view_tree.addElement(username_input.asElement());
    try view_tree.addElement(password_input.asElement());
    view_tree.focus(username_input.getId());

    // Create scene
    var scene = Scene.init(allocator);
    defer scene.deinit();

    // Build render context
    var render_ctx = RenderContext{
        .allocator = allocator,
        .text_system = &text_system,
        .layout_engine = &layout_engine,
        .scene = &scene,
        .username_input = &username_input,
        .password_input = &password_input,
        .view_tree = &view_tree,
        .scale_factor = @floatCast(window.scale_factor),
        .window_width = 800,
        .window_height = 600,
    };
    g_render_ctx = &render_ctx;

    // Create reactive app state
    var app_state = app.new(AppState, struct {
        fn build(_: *Context(AppState)) AppState {
            return .{
                .username = "",
                .password = "",
                .login_attempts = 0,
                .is_submitting = false,
                .error_message = null,
                .focused_field = .username,
            };
        }
    }.build);
    defer app_state.release();
    g_app_state = app_state;

    // Set as root view for reactive rendering
    window.setRootView(AppState, app_state);

    // Set up render callback - this converts state to scene
    window.setRenderCallback(onRender);

    // Set up input handling
    window.setInputCallback(onInput);

    // Initial render
    try buildScene(&render_ctx, &app);

    window.setTextAtlas(text_system.getAtlas());
    window.setScene(&scene);

    std.debug.print("Ready! Tab to switch fields, Enter to submit, Escape to cancel\n", .{});

    app.run(null);
}

// =============================================================================
// Render Callback
// =============================================================================

fn onRender(window: *gooey.Window, output: RenderOutput) void {
    _ = output;
    if (g_render_ctx) |ctx| {
        if (g_app) |app| {
            buildScene(ctx, app) catch |err| {
                std.debug.print("Render error: {}\n", .{err});
            };
            window.setTextAtlas(ctx.text_system.getAtlas());
        }
    }
}

// =============================================================================
// Input Handling
// =============================================================================

fn onInput(window: *gooey.Window, event: gooey.InputEvent) bool {
    const ctx = g_render_ctx orelse return false;
    const app = g_app orelse return false;
    const state_entity = g_app_state orelse return false;

    // Handle keyboard shortcuts
    if (event == .key_down) {
        const k = event.key_down;

        // Tab - switch focus
        if (k.key == .tab) {
            app.update(AppState, state_entity, struct {
                fn update(state: *AppState, cx: *Context(AppState)) void {
                    state.focused_field = switch (state.focused_field) {
                        .none, .password => .username,
                        .username => .password,
                    };
                    // Update view tree focus
                    if (g_render_ctx) |render_ctx| {
                        switch (state.focused_field) {
                            .username => render_ctx.view_tree.focus(render_ctx.username_input.getId()),
                            .password => render_ctx.view_tree.focus(render_ctx.password_input.getId()),
                            .none => render_ctx.view_tree.blur(),
                        }
                    }
                    _ = cx;
                }
            }.update);
            app.markDirty(state_entity.entityId());
            rebuildAndRefresh(window, ctx, app);
            return true;
        }

        // Enter - submit
        if (k.key == .@"return") {
            app.update(AppState, state_entity, struct {
                fn update(state: *AppState, _: *Context(AppState)) void {
                    state.login_attempts += 1;
                    // Get actual text from inputs
                    if (g_render_ctx) |render_ctx| {
                        state.username = render_ctx.username_input.getText();
                        state.password = render_ctx.password_input.getText();
                    }

                    if (state.username.len == 0) {
                        state.error_message = "Username required";
                    } else if (state.password.len == 0) {
                        state.error_message = "Password required";
                    } else {
                        state.error_message = null;
                        std.debug.print("Login #{}: {s}\n", .{ state.login_attempts, state.username });
                    }
                }
            }.update);
            app.markDirty(state_entity.entityId());
            rebuildAndRefresh(window, ctx, app);
            return true;
        }

        // Escape - cancel
        if (k.key == .escape) {
            ctx.username_input.clear();
            ctx.password_input.clear();
            app.update(AppState, state_entity, struct {
                fn update(state: *AppState, _: *Context(AppState)) void {
                    state.error_message = null;
                    state.focused_field = .username;
                }
            }.update);
            ctx.view_tree.focus(ctx.username_input.getId());
            app.markDirty(state_entity.entityId());
            rebuildAndRefresh(window, ctx, app);
            return true;
        }
    }

    // Forward to view tree (text inputs)
    const handled = ctx.view_tree.dispatchEvent(event);
    if (handled) {
        rebuildAndRefresh(window, ctx, app);
    }
    return handled;
}

fn rebuildAndRefresh(window: *gooey.Window, ctx: *RenderContext, app: *gooey.App) void {
    buildScene(ctx, app) catch {};
    window.setTextAtlas(ctx.text_system.getAtlas());
}

// =============================================================================
// Scene Building
// =============================================================================

fn buildScene(ctx: *RenderContext, app: *gooey.App) !void {
    // Prevent re-entrant builds (can happen when input and render callbacks overlap)
    if (g_building_scene) return;
    g_building_scene = true;
    defer g_building_scene = false;

    ctx.scene.clear();

    // Read current state
    const state_entity = g_app_state orelse return;
    const state = app.read(AppState, state_entity) orelse return;

    ctx.layout_engine.beginFrame(ctx.window_width, ctx.window_height);

    // Root container
    try ctx.layout_engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{
            .sizing = Sizing.fill(),
            .layout_direction = .top_to_bottom,
            .child_alignment = ChildAlignment.center(),
            .padding = Padding.all(20),
        },
    });
    {
        // Header with attempt count
        try ctx.layout_engine.openElement(.{
            .id = LayoutId.init("header"),
            .layout = .{ .sizing = .{ .width = SizingAxis.fit(), .height = SizingAxis.fixed(40) } },
        });
        var header_buf: [64]u8 = undefined;
        const header_text = if (state.login_attempts > 0)
            std.fmt.bufPrint(&header_buf, "Welcome! (Attempts: {})", .{state.login_attempts}) catch "Welcome!"
        else
            "Welcome to gooey!";
        try ctx.layout_engine.text(header_text, .{
            .color = Color.rgb(0.2, 0.2, 0.2),
            .font_size = 24,
        });
        ctx.layout_engine.closeElement();

        // Error message (if any)
        if (state.error_message) |err_msg| {
            try ctx.layout_engine.openElement(.{
                .id = LayoutId.init("error"),
                .layout = .{ .sizing = Sizing.fitContent(), .padding = Padding.symmetric(0, 8) },
                .background_color = Color.rgb(1.0, 0.9, 0.9),
                .corner_radius = CornerRadius.all(4),
            });
            try ctx.layout_engine.text(err_msg, .{ .color = Color.rgb(0.8, 0.2, 0.2) });
            ctx.layout_engine.closeElement();
        }

        // Card
        try ctx.layout_engine.openElement(.{
            .id = LayoutId.init("card"),
            .layout = .{
                .sizing = .{ .width = SizingAxis.fixed(400), .height = SizingAxis.fit() },
                .layout_direction = .top_to_bottom,
                .padding = Padding.all(24),
                .child_gap = 16,
                .child_alignment = .{ .x = .center, .y = .top },
            },
            .background_color = Color.white,
            .corner_radius = CornerRadius.all(12),
        });
        {
            // Title
            try ctx.layout_engine.openElement(.{
                .id = LayoutId.init("title"),
                .layout = .{ .sizing = Sizing.fitContent() },
            });
            try ctx.layout_engine.text("Login", .{ .color = Color.rgb(0.1, 0.1, 0.1), .font_size = 20 });
            ctx.layout_engine.closeElement();

            // Username container
            try ctx.layout_engine.openElement(.{
                .id = LayoutId.init("username_container"),
                .layout = .{ .sizing = .{ .width = SizingAxis.percent(1.0), .height = SizingAxis.fixed(36) } },
            });
            ctx.layout_engine.closeElement();

            // Password container
            try ctx.layout_engine.openElement(.{
                .id = LayoutId.init("password_container"),
                .layout = .{ .sizing = .{ .width = SizingAxis.percent(1.0), .height = SizingAxis.fixed(36) } },
            });
            ctx.layout_engine.closeElement();

            // Buttons
            try ctx.layout_engine.openElement(.{
                .id = LayoutId.init("button_row"),
                .layout = .{
                    .sizing = .{ .width = SizingAxis.percent(1.0), .height = SizingAxis.fixed(44) },
                    .layout_direction = .left_to_right,
                    .child_gap = 12,
                    .child_alignment = ChildAlignment.center(),
                },
            });
            {
                try ctx.layout_engine.openElement(.{
                    .id = LayoutId.init("cancel_btn"),
                    .layout = .{ .sizing = Sizing.fixed(100, 36), .child_alignment = ChildAlignment.center() },
                    .background_color = Color.rgb(0.9, 0.9, 0.9),
                    .corner_radius = CornerRadius.all(6),
                });
                try ctx.layout_engine.text("Cancel", .{ .color = Color.rgb(0.3, 0.3, 0.3) });
                ctx.layout_engine.closeElement();

                try ctx.layout_engine.openElement(.{
                    .id = LayoutId.init("submit_btn"),
                    .layout = .{ .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(36) }, .child_alignment = ChildAlignment.center() },
                    .background_color = if (state.is_submitting) Color.rgb(0.5, 0.7, 1.0) else Color.rgb(0.2, 0.5, 1.0),
                    .corner_radius = CornerRadius.all(6),
                });
                try ctx.layout_engine.text(if (state.is_submitting) "Signing in..." else "Sign In", .{ .color = Color.white });
                ctx.layout_engine.closeElement();
            }
            ctx.layout_engine.closeElement();
        }
        ctx.layout_engine.closeElement();

        // Footer
        try ctx.layout_engine.openElement(.{
            .id = LayoutId.init("footer"),
            .layout = .{ .sizing = Sizing.fitContent(), .padding = Padding.symmetric(0, 20) },
        });
        try ctx.layout_engine.text("Tab: switch | Enter: submit | Esc: cancel", .{
            .color = Color.rgb(0.5, 0.5, 0.5),
            .font_size = 12,
        });
        ctx.layout_engine.closeElement();
    }
    ctx.layout_engine.closeElement();

    const commands = try ctx.layout_engine.endFrame();

    // Draw shadow for card
    if (ctx.layout_engine.getBoundingBox(LayoutId.init("card").id)) |box| {
        try ctx.scene.insertShadow(Shadow.drop(box.x, box.y, box.width, box.height, 15)
            .withCornerRadius(12)
            .withColor(Hsla.init(0, 0, 0, 0.12)));
    }

    // Render commands
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .rectangle => {
                const rect = cmd.data.rectangle;
                try ctx.scene.insertQuad(Quad{
                    .bounds_origin_x = cmd.bounding_box.x,
                    .bounds_origin_y = cmd.bounding_box.y,
                    .bounds_size_width = cmd.bounding_box.width,
                    .bounds_size_height = cmd.bounding_box.height,
                    .background = layout.colorToHsla(rect.background_color),
                    .corner_radii = .{
                        .top_left = rect.corner_radius.top_left,
                        .top_right = rect.corner_radius.top_right,
                        .bottom_left = rect.corner_radius.bottom_left,
                        .bottom_right = rect.corner_radius.bottom_right,
                    },
                });
            },
            .text => {
                const text_data = cmd.data.text;
                try renderText(ctx.scene, ctx.text_system, text_data.text, cmd.bounding_box.x, cmd.bounding_box.y + cmd.bounding_box.height * 0.75, ctx.scale_factor, layout.colorToHsla(text_data.color));
            },
            else => {},
        }
    }

    // Render text inputs at layout positions
    if (ctx.layout_engine.getBoundingBox(LayoutId.init("username_container").id)) |box| {
        ctx.username_input.bounds = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        try ctx.username_input.render(ctx.scene, ctx.text_system, ctx.scale_factor);
    }
    if (ctx.layout_engine.getBoundingBox(LayoutId.init("password_container").id)) |box| {
        ctx.password_input.bounds = .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height };
        try ctx.password_input.render(ctx.scene, ctx.text_system, ctx.scale_factor);
    }

    ctx.scene.finish();
}

// =============================================================================
// Helpers
// =============================================================================

fn measureTextCallback(text: []const u8, _: u16, _: u16, _: ?f32, user_data: ?*anyopaque) layout.engine.TextMeasurement {
    if (user_data) |ptr| {
        const ts: *gooey.TextSystem = @ptrCast(@alignCast(ptr));
        const width = ts.measureText(text) catch 0;
        const metrics = ts.getMetrics();
        return .{ .width = width, .height = if (metrics) |m| m.line_height else 20 };
    }
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10, .height = 20 };
}

fn renderText(scene: *Scene, text_system: *gooey.TextSystem, text: []const u8, x: f32, baseline_y: f32, scale_factor: f32, color: Hsla) !void {
    var shaped = try text_system.shapeText(text);
    defer shaped.deinit(text_system.allocator);

    var pen_x = x;
    for (shaped.glyphs) |glyph| {
        const cached = try text_system.getGlyph(glyph.glyph_id);
        if (cached.region.width > 0 and cached.region.height > 0) {
            const atlas = text_system.getAtlas();
            const uv = cached.region.uv(atlas.size);
            try scene.insertGlyph(gooey.GlyphInstance.init(
                pen_x + glyph.x_offset + cached.bearing_x,
                baseline_y + glyph.y_offset - cached.bearing_y,
                @as(f32, @floatFromInt(cached.region.width)) / scale_factor,
                cached.height,
                uv.u0,
                uv.v0,
                uv.u1,
                uv.v1,
                color,
            ));
        }
        pen_x += glyph.x_advance;
    }
}
