const std = @import("std");
const gooey = @import("gooey");

// Layout imports
const layout = gooey.layout;
const LayoutEngine = layout.LayoutEngine;
const LayoutId = layout.LayoutId;
const Sizing = layout.Sizing;
const SizingAxis = layout.SizingAxis;
const LayoutConfig = layout.LayoutConfig;
const Padding = layout.Padding;
const Color = layout.Color;
const CornerRadius = layout.CornerRadius;
const ChildAlignment = layout.ChildAlignment;
const TextConfig = layout.TextConfig;
const RenderCommandType = layout.RenderCommandType;

// Existing gooey types
const TextInput = gooey.TextInput;
const ViewTree = gooey.ViewTree;
const Scene = gooey.Scene;
const Hsla = gooey.Hsla;
const Quad = gooey.Quad;
const Shadow = gooey.Shadow;

// Application state
var g_view_tree: ?*ViewTree = null;
var g_username_input: ?*TextInput = null;
var g_password_input: ?*TextInput = null;
var g_text_system: ?*gooey.TextSystem = null;
var g_layout_engine: ?*LayoutEngine = null;
var g_scale_factor: f32 = 1.0;
var g_window_width: f32 = 800;
var g_window_height: f32 = 600;

pub fn main() !void {
    std.debug.print("Starting gooey with layout system...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try gooey.App.init(allocator);
    defer app.deinit();

    var window = try app.createWindow(.{
        .title = "gooey - Layout System Demo",
        .width = 800,
        .height = 600,
        .background_color = gooey.Color.init(0.95, 0.95, 0.95, 1.0),
    });
    defer window.deinit();

    g_window_width = 800;
    g_window_height = 600;

    // Initialize text system
    var text_system = try gooey.TextSystem.initWithScale(allocator, @floatCast(window.scale_factor));
    defer text_system.deinit();
    g_text_system = &text_system;
    g_scale_factor = @floatCast(window.scale_factor);
    try text_system.loadFont("Menlo", 16.0);

    // Initialize layout engine
    var layout_engine = LayoutEngine.init(allocator);
    defer layout_engine.deinit();
    g_layout_engine = &layout_engine;

    // Set up text measurement callback
    layout_engine.setMeasureTextFn(measureTextCallback, &text_system);

    // Create text inputs (existing elements - positioned by layout)
    var username_input = TextInput.init(allocator, .{
        .x = 0, // Will be positioned by layout
        .y = 0,
        .width = 300,
        .height = 36,
    });
    defer username_input.deinit();
    username_input.setPlaceholder("Username");
    g_username_input = &username_input;

    var password_input = TextInput.init(allocator, .{
        .x = 0,
        .y = 0,
        .width = 300,
        .height = 36,
    });
    defer password_input.deinit();
    password_input.setPlaceholder("Password");
    g_password_input = &password_input;

    // Build view tree
    var view_tree = ViewTree.init(allocator);
    defer view_tree.deinit();
    g_view_tree = &view_tree;

    try view_tree.addElement(username_input.asElement());
    try view_tree.addElement(password_input.asElement());
    view_tree.focus(username_input.getId());

    window.setInputCallback(onInput);

    // Build scene with layout
    var scene = Scene.init(allocator);
    defer scene.deinit();
    try buildSceneWithLayout(&scene, &layout_engine, &text_system, &username_input, &password_input);
    window.setTextAtlas(text_system.getAtlas());
    window.setScene(&scene);

    std.debug.print("Layout system ready!\n", .{});
    std.debug.print("- Layout: vertical column with centered card\n", .{});
    std.debug.print("- Tab to switch focus\n", .{});

    app.run(null);
}

/// Text measurement callback for layout engine
fn measureTextCallback(
    text: []const u8,
    _: u16, // font_id
    _: u16, // font_size
    _: ?f32, // max_width
    user_data: ?*anyopaque,
) layout.engine.TextMeasurement {
    if (user_data) |ptr| {
        const ts: *gooey.TextSystem = @ptrCast(@alignCast(ptr));
        const width = ts.measureText(text) catch 0;
        const metrics = ts.getMetrics();
        const height = if (metrics) |m| m.line_height else 20;
        return .{ .width = width, .height = height };
    }
    return .{ .width = @as(f32, @floatFromInt(text.len)) * 10, .height = 20 };
}

/// Build scene using the layout system
fn buildSceneWithLayout(
    scene: *Scene,
    layout_engine: *LayoutEngine,
    text_system: *gooey.TextSystem,
    username_input: *TextInput,
    password_input: *TextInput,
) !void {
    scene.clear();

    // =======================================================================
    // LAYOUT PASS - declare UI structure
    // =======================================================================
    layout_engine.beginFrame(g_window_width, g_window_height);

    // Root container - fills viewport, centers children
    try layout_engine.openElement(.{
        .id = LayoutId.init("root"),
        .layout = .{
            .sizing = Sizing.fill(),
            .layout_direction = .top_to_bottom,
            .child_alignment = ChildAlignment.center(),
            .padding = Padding.all(20),
        },
    });
    {
        // Header text
        try layout_engine.openElement(.{
            .id = LayoutId.init("header"),
            .layout = .{
                .sizing = .{ .width = SizingAxis.fit(), .height = SizingAxis.fixed(40) },
            },
        });
        try layout_engine.text("Welcome to gooey!", .{
            .color = Color.rgb(0.2, 0.2, 0.2),
            .font_size = 24,
        });
        layout_engine.closeElement();

        // Card container
        try layout_engine.openElement(.{
            .id = LayoutId.init("card"),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(400),
                    .height = SizingAxis.fit(),
                },
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
            try layout_engine.openElement(.{
                .id = LayoutId.init("title"),
                .layout = .{ .sizing = Sizing.fitContent() },
            });
            try layout_engine.text("Login", .{
                .color = Color.rgb(0.1, 0.1, 0.1),
                .font_size = 20,
            });
            layout_engine.closeElement();

            // Username field container
            try layout_engine.openElement(.{
                .id = LayoutId.init("username_container"),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.percent(1.0), // 100% of card content
                        .height = SizingAxis.fixed(36),
                    },
                },
            });
            layout_engine.closeElement();

            // Password field container
            try layout_engine.openElement(.{
                .id = LayoutId.init("password_container"),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.percent(1.0),
                        .height = SizingAxis.fixed(36),
                    },
                },
            });
            layout_engine.closeElement();

            // Button row
            try layout_engine.openElement(.{
                .id = LayoutId.init("button_row"),
                .layout = .{
                    .sizing = .{
                        .width = SizingAxis.percent(1.0),
                        .height = SizingAxis.fixed(44),
                    },
                    .layout_direction = .left_to_right,
                    .child_gap = 12,
                    .child_alignment = ChildAlignment.center(),
                },
            });
            {
                // Cancel button
                try layout_engine.openElement(.{
                    .id = LayoutId.init("cancel_btn"),
                    .layout = .{
                        .sizing = Sizing.fixed(100, 36),
                        .child_alignment = ChildAlignment.center(),
                    },
                    .background_color = Color.rgb(0.9, 0.9, 0.9),
                    .corner_radius = CornerRadius.all(6),
                });
                try layout_engine.text("Cancel", .{ .color = Color.rgb(0.3, 0.3, 0.3) });
                layout_engine.closeElement();

                // Submit button
                try layout_engine.openElement(.{
                    .id = LayoutId.init("submit_btn"),
                    .layout = .{
                        .sizing = .{ .width = SizingAxis.grow(), .height = SizingAxis.fixed(36) },
                        .child_alignment = ChildAlignment.center(),
                    },
                    .background_color = Color.rgb(0.2, 0.5, 1.0),
                    .corner_radius = CornerRadius.all(6),
                });
                try layout_engine.text("Sign In", .{ .color = Color.white });
                layout_engine.closeElement();
            }
            layout_engine.closeElement(); // button_row
        }
        layout_engine.closeElement(); // card

        // Footer
        try layout_engine.openElement(.{
            .id = LayoutId.init("footer"),
            .layout = .{
                .sizing = Sizing.fitContent(),
                .padding = Padding.symmetric(0, 20),
            },
        });
        try layout_engine.text("Built with gooey layout system", .{
            .color = Color.rgb(0.5, 0.5, 0.5),
            .font_size = 12,
        });
        layout_engine.closeElement();
    }
    layout_engine.closeElement(); // root

    // Get computed layout
    const commands = try layout_engine.endFrame();

    // =======================================================================
    // RENDER PASS - convert layout commands to scene primitives
    // =======================================================================

    // First, draw shadow for the card
    if (layout_engine.getBoundingBox(LayoutId.init("card").id)) |card_box| {
        const shadow = Shadow.drop(card_box.x, card_box.y, card_box.width, card_box.height, 15)
            .withCornerRadius(12)
            .withColor(Hsla.init(0, 0, 0, 0.12));
        try scene.insertShadow(shadow);
    }

    // Render layout commands
    for (commands) |cmd| {
        switch (cmd.command_type) {
            .rectangle => {
                const rect = cmd.data.rectangle;
                const quad = Quad{
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
                };
                try scene.insertQuad(quad);
            },
            .text => {
                const text_data = cmd.data.text;
                try renderText(
                    scene,
                    text_system,
                    text_data.text,
                    cmd.bounding_box.x,
                    cmd.bounding_box.y + cmd.bounding_box.height * 0.75, // baseline
                    g_scale_factor,
                    layout.colorToHsla(text_data.color),
                );
            },
            else => {},
        }
    }

    // =======================================================================
    // Position and render existing TextInput elements using layout bounds
    // =======================================================================

    if (layout_engine.getBoundingBox(LayoutId.init("username_container").id)) |box| {
        username_input.bounds = .{
            .x = box.x,
            .y = box.y,
            .width = box.width,
            .height = box.height,
        };
        try username_input.render(scene, text_system, g_scale_factor);
    }

    if (layout_engine.getBoundingBox(LayoutId.init("password_container").id)) |box| {
        password_input.bounds = .{
            .x = box.x,
            .y = box.y,
            .width = box.width,
            .height = box.height,
        };
        try password_input.render(scene, text_system, g_scale_factor);
    }

    scene.finish();
}

fn onInput(window: *gooey.Window, input_event: gooey.InputEvent) bool {
    if (g_view_tree) |tree| {
        if (input_event == .key_down) {
            const k = input_event.key_down;
            if (k.key == .tab) {
                if (g_username_input) |u| {
                    if (g_password_input) |p| {
                        if (tree.focused_id.eql(u.getId())) {
                            tree.focus(p.getId());
                        } else {
                            tree.focus(u.getId());
                        }
                        rebuildScene(window);
                        return true;
                    }
                }
            }
        }

        const handled = tree.dispatchEvent(input_event);
        if (handled) {
            rebuildScene(window);
        }
        return handled;
    }
    return false;
}

fn rebuildScene(window: *gooey.Window) void {
    if (g_text_system) |ts| {
        if (g_layout_engine) |le| {
            if (g_username_input) |u| {
                if (g_password_input) |p| {
                    if (window.scene) |scene| {
                        const s: *Scene = @constCast(scene);
                        buildSceneWithLayout(s, le, ts, u, p) catch {};
                        window.setTextAtlas(ts.getAtlas());
                    }
                }
            }
        }
    }
}

/// Render text at the given baseline position
fn renderText(
    scene: *Scene,
    text_system: *gooey.TextSystem,
    text: []const u8,
    x: f32,
    baseline_y: f32,
    scale_factor: f32,
    color: Hsla,
) !void {
    var shaped = try text_system.shapeText(text);
    defer shaped.deinit(text_system.allocator);

    var pen_x = x;
    for (shaped.glyphs) |glyph| {
        const cached = try text_system.getGlyph(glyph.glyph_id);

        if (cached.region.width > 0 and cached.region.height > 0) {
            const atlas = text_system.getAtlas();
            const uv = cached.region.uv(atlas.size);

            const glyph_x = pen_x + glyph.x_offset + cached.bearing_x;
            const glyph_y = baseline_y + glyph.y_offset - cached.bearing_y;
            const glyph_w = @as(f32, @floatFromInt(cached.region.width)) / scale_factor;
            const glyph_h = cached.height;

            try scene.insertGlyph(gooey.GlyphInstance.init(
                glyph_x,
                glyph_y,
                glyph_w,
                glyph_h,
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
