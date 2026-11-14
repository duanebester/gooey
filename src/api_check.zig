//! Compile-time pin list for Gooey's public API.
//!
//! Every name referenced below is a promise: deleting or renaming it must
//! be an explicit, intentional act that updates this file in the same
//! change. The list is the whole public surface of `root.zig`: the names an
//! app writes as `gooey.<Name>`, and the namespaces handlers and
//! accessibility fields reach into. `gooey.internals` and `gooey.testing`
//! are deliberately unpinned: neither is API.
//!
//! If a pinned name disappears, `zig build test` (which reaches this file
//! from `root.zig`'s test block) fails at comptime at that name's line.

const gooey = @import("root.zig");

/// The flat names: the app entry point, render context, element
/// constructors, handlers, identity, retained state, and budget.
fn pinSurface() void {
    comptime {
        _ = @TypeOf(gooey.App);
        _ = gooey.Config;
        _ = gooey.Cx;
        _ = gooey.ui;
        _ = gooey.Handler;
        _ = gooey.Effects;
        _ = gooey.Entity;
        _ = gooey.ElementId;
        _ = gooey.Key;
        _ = gooey.Lifetime;
        _ = gooey.Handle;
        _ = gooey.Query;
        _ = @TypeOf(gooey.Drag);
        _ = gooey.Theme;
        _ = gooey.Painter;
        _ = gooey.PathPromptOptions;
        _ = gooey.SavePromptOptions;
        _ = gooey.Paths;
        _ = gooey.InputEngine;
        _ = gooey.AreaEngine;
        _ = gooey.EditorEngine;
        _ = gooey.ResourceLimits;
        _ = gooey.FontLimits;
        _ = gooey.FontSource;
        _ = gooey.Color;
        _ = gooey.log;
        _ = gooey.std_options;
    }
}

/// `gooey.ui`: the element constructors every render function calls and
/// the style types their options name.
fn pinUi() void {
    comptime {
        _ = @TypeOf(gooey.ui.box);
        _ = @TypeOf(gooey.ui.text);
        _ = @TypeOf(gooey.ui.paint);
        _ = @TypeOf(gooey.ui.when);
        _ = @TypeOf(gooey.ui.action);
        _ = @TypeOf(gooey.ui.Paint);
        _ = gooey.ui.Box;
        _ = gooey.ui.Style;
        _ = gooey.ui.DragSource;
        _ = gooey.ui.DropTarget;
        _ = gooey.ui.Text;
        _ = gooey.ui.Color;
        _ = gooey.ui.A11y;
        _ = gooey.ui.Painter;
        _ = gooey.ui.Role;
        _ = gooey.ui.Orientation;
        _ = gooey.ui.HeadingLevel;
        _ = gooey.ui.Rect;
    }
}

/// The fields apps set by name. A rename breaks every literal that names
/// the field, so each is pinned here, not only its containing type.
fn pinFields() void {
    comptime {
        const Box = gooey.ui.Box;
        for ([_][]const u8{
            "key",      "style",           "layer",     "focusable",
            "tab_stop", "key_context",     "on_click",  "on_click_outside",
            "on_key",   "on_pointer_drag", "draggable", "drop_target",
            "actions",  "a11y",
        }) |name| {
            _ = @FieldType(Box, name);
        }
        _ = @TypeOf(gooey.ui.DragSource.of);
        _ = @TypeOf(gooey.ui.DropTarget.of);
        const Layer = @typeInfo(@FieldType(Box, "layer")).optional.child;
        _ = @as(@FieldType(Layer, "kind"), .drag);
        for ([_][]const u8{ "payload", "over", "x", "y" }) |name| {
            _ = @FieldType(gooey.Drag(u32), name);
        }
        const A11y = gooey.ui.A11y;
        for ([_][]const u8{
            "role",     "label",         "value",      "checked",  "selected",
            "disabled", "heading_level", "live",       "href",     "description",
            "expanded", "has_popup",     "pos_in_set", "set_size", "range",
        }) |name| {
            _ = @FieldType(A11y, name);
        }
        for ([_][]const u8{ "min", "max", "now", "orientation" }) |name| {
            _ = @FieldType(A11y.Range, name);
        }
        const Cursor = @typeInfo(@FieldType(gooey.ui.Style, "cursor")).optional.child;
        _ = @as(Cursor, .default);
        _ = @as(Cursor, .text);
        _ = @as(Cursor, .pointer);
        _ = @as(Cursor, .resize_left_right);
        _ = @as(Cursor, .resize_up_down);
        _ = @FieldType(@FieldType(gooey.ResourceLimits, "text"), "fonts");
        _ = @FieldType(@FieldType(gooey.ResourceLimits, "build"), "box_depth_max");
    }
}

/// `Effects`: what handlers ask the framework for.
fn pinEffects() void {
    comptime {
        const Effects = gooey.Effects;
        _ = @TypeOf(Effects.focus);
        _ = @TypeOf(Effects.blur);
        _ = @TypeOf(Effects.click);
        _ = @TypeOf(Effects.quit);
        _ = @TypeOf(Effects.requestRender);
        _ = @TypeOf(Effects.stopPropagation);
        _ = @TypeOf(Effects.openFileDialog);
        _ = @TypeOf(Effects.setTheme);
        _ = @TypeOf(Effects.setFont);
        _ = @TypeOf(Effects.announce);
        _ = @TypeOf(Effects.create);
        _ = @TypeOf(Effects.remove);
        _ = @TypeOf(Effects.handler);
        _ = @TypeOf(Effects.inputEvent);
        _ = @TypeOf(Effects.completionEvent);
        _ = @TypeOf(Effects.pointerDrag);
        _ = @TypeOf(Effects.bounds);
        _ = @TypeOf(Effects.dropPayload);
        const drag_fields = .{ "phase", "x", "y", "start_x", "start_y", "button", "modifiers" };
        for (drag_fields) |name| {
            _ = @FieldType(Effects.PointerDrag, name);
        }
        _ = Effects.PointerDrag.Phase.cancel;
    }
}

/// The namespaces whose types handlers and accessibility fields name.
fn pinNamespaces() void {
    comptime {
        _ = gooey.animation;
        _ = gooey.input.InputEvent;
        _ = gooey.input.KeyCode;
        _ = gooey.input.Modifiers;
        _ = gooey.input.Keystroke;
        _ = @TypeOf(gooey.text.codepointCount);
        _ = gooey.text.run_codepoint_count_max;
        _ = gooey.accessibility.Role;
        _ = gooey.accessibility.State;
        _ = gooey.accessibility.Live;
        _ = gooey.accessibility.HeadingLevel;
        _ = gooey.accessibility.Orientation;
    }
}

/// `Cx`'s most-used methods: every render function calls these.
fn pinCx() void {
    comptime {
        _ = @TypeOf(gooey.Cx.state);
        _ = @TypeOf(gooey.Cx.render);
        _ = @TypeOf(gooey.Cx.on);
        _ = @TypeOf(gooey.Cx.theme);
        _ = @TypeOf(gooey.Cx.drag);
    }
}

test "public API surface compiles" {
    comptime {
        pinSurface();
        pinUi();
        pinFields();
        pinEffects();
        pinNamespaces();
        pinCx();
    }
}
