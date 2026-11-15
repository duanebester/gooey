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
//! `pinExact` closes the other direction: a public name added to the root
//! or to one of its namespaces without a line here fails too, so this file
//! describes the whole surface.

const std = @import("std");
const gooey = @import("root.zig");

/// The flat names: the app entry point, render context, element
/// constructors, handlers, identity, retained state, and budget.
fn pinSurface() void {
    comptime {
        _ = @TypeOf(gooey.App);
        _ = gooey.Config;
        _ = gooey.Init;
        _ = @TypeOf(gooey.Job);
        _ = gooey.JobId;
        _ = gooey.Cx;
        _ = gooey.ui;
        _ = gooey.Handler;
        _ = gooey.Effects;
        _ = gooey.Entity;
        _ = gooey.ElementId;
        _ = gooey.Key;
        _ = gooey.Lifetime;
        _ = gooey.Handle;
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
        _ = gooey.ui.Direction;
        _ = gooey.ui.Layer;
        _ = gooey.ui.Anchor;
        _ = gooey.ui.Scroll;
        _ = gooey.ui.ClipPolicy;
        _ = gooey.ui.CursorShape;
        _ = gooey.ui.PointerEvents;
        _ = gooey.ui.KeyContext;
        _ = gooey.ui.ActionBinding;
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
        _ = gooey.ui.ScrollAnchor;
        _ = gooey.ui.ScrollTarget;
        _ = gooey.ui.ScrollOffset;
        _ = gooey.ui.ScrollChild;
        _ = gooey.ui.ScrollAlignment;
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
        for ([_][]const u8{ "payload", "over", "x", "y", "keyboard" }) |name| {
            _ = @FieldType(gooey.Drag(u32), name);
        }
        const A11y = gooey.ui.A11y;
        for ([_][]const u8{
            "role",      "label",         "value",      "checked",  "selected",
            "disabled",  "heading_level", "live",       "href",     "description",
            "expanded",  "has_popup",     "pos_in_set", "set_size", "range",
            "selection",
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
        const Text = @FieldType(gooey.ResourceLimits, "text");
        for ([_][]const u8{
            "fonts",                  "glyph_cache_count_max", "shaped_run_count_max",
            "measure_slot_count_max", "preedit_bytes_max",
        }) |name| {
            _ = @FieldType(Text, name);
        }
        _ = @FieldType(@FieldType(gooey.ResourceLimits, "build"), "box_depth_max");
        const Atlas = @FieldType(gooey.ResourceLimits, "atlas");
        for ([_][]const u8{
            "svg_entry_count_max",   "svg_rasterization_count_frame_max",
            "image_entry_count_max", "image_path_bytes_max",
        }) |name| {
            _ = @FieldType(Atlas, name);
        }
        _ = @FieldType(@FieldType(gooey.ResourceLimits, "a11y"), "value_bytes_max");
        const Events = @FieldType(gooey.ResourceLimits, "events");
        for ([_][]const u8{
            "dialog_count_max",     "job_count_max",        "job_input_bytes_max",
            "job_result_count_max", "job_result_bytes_max",
        }) |name| {
            _ = @FieldType(Events, name);
        }
        const AppConfig = gooey.Config(struct {});
        for ([_][]const u8{ "jobs", "on_init", "on_deinit" }) |name| {
            _ = @FieldType(AppConfig, name);
        }
        for ([_][]const u8{ "io", "environ" }) |name| {
            _ = @FieldType(gooey.Init, name);
        }
        for ([_][]const u8{ "slot", "generation" }) |name| {
            _ = @FieldType(gooey.JobId, name);
        }
        for ([_][]const u8{ "x", "y", "anchor" }) |name| {
            _ = @FieldType(gooey.ui.Scroll, name);
        }
        _ = @as(gooey.ui.ScrollAnchor, .end);
        _ = @as(gooey.ui.ScrollTarget, .start);
        _ = @as(gooey.ui.ScrollTarget, .end);
        _ = @as(gooey.ui.ScrollTarget, .{ .offset = .{ .x = 0, .y = 0 } });
        _ = @as(gooey.ui.ScrollTarget, .{ .child = .{
            .key = .{ .index = 0 },
            .alignment = .nearest,
        } });
        _ = @as(gooey.ui.ScrollAlignment, .start);
        _ = @as(gooey.ui.ScrollAlignment, .center);
        _ = @as(gooey.ui.ScrollAlignment, .end);
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
        _ = @TypeOf(Effects.startDrag);
        _ = @TypeOf(Effects.spawn);
        _ = @TypeOf(Effects.cancelJob);
        _ = @TypeOf(Effects.jobResult);
        _ = @TypeOf(Effects.jobDone);
        _ = @TypeOf(Effects.jobId);
        for ([_][]const u8{ "on_result", "on_done" }) |name| {
            _ = @FieldType(Effects.JobHandlers, name);
        }
        for ([_][]const u8{ "id", "outcome" }) |name| {
            _ = @FieldType(Effects.JobDone, name);
        }
        _ = Effects.JobOutcome.finished;
        _ = Effects.JobOutcome.cancelled;
        _ = @FieldType(Effects.JobOutcome, "failed");
        for ([_][]const u8{ "io", "cancelled", "post" }) |name| {
            if (!@hasDecl(gooey.Job(u8), name)) @compileError("gooey.Job lost " ++ name);
        }
        _ = @TypeOf(Effects.scrollTo);
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
        _ = @FieldType(gooey.input.InputEvent, "focus_lost");
        _ = @FieldType(gooey.input.FocusLostEvent, "keys_held");
        _ = gooey.input.held_key_count_max;
        _ = gooey.input.KeyCode;
        _ = gooey.input.Modifiers;
        _ = gooey.input.Keystroke;
        _ = @TypeOf(gooey.text.codepointCount);
        _ = gooey.text.run_codepoint_count_max;
        _ = gooey.text.Metrics;
        _ = gooey.text.FontWeight;
        _ = gooey.text.FontFamily;
        _ = gooey.text.FontVariant;
        _ = gooey.accessibility.Role;
        _ = gooey.accessibility.State;
        _ = gooey.accessibility.Live;
        _ = gooey.accessibility.HeadingLevel;
        _ = gooey.accessibility.Orientation;
    }
}

/// `Cx`'s methods: it is opaque, so these are everything a render function
/// or component reaches during a build.
fn pinCx() void {
    comptime {
        const Cx = gooey.Cx;
        _ = @TypeOf(Cx.state);
        _ = @TypeOf(Cx.render);
        _ = @TypeOf(Cx.on);
        _ = @TypeOf(Cx.id);
        _ = @TypeOf(Cx.theme);
        _ = @TypeOf(Cx.fontMetrics);
        _ = @TypeOf(Cx.hovered);
        _ = @TypeOf(Cx.focused);
        _ = @TypeOf(Cx.requestRenderAfter);
        _ = @TypeOf(Cx.now);
        _ = @TypeOf(Cx.limits);
        _ = @TypeOf(Cx.bounds);
        _ = @TypeOf(Cx.scroll);
        _ = @TypeOf(Cx.retain);
        _ = @TypeOf(Cx.get);
        _ = @TypeOf(Cx.release);
        _ = @TypeOf(Cx.drag);
        for ([_][]const u8{ "offset_x", "offset_y", "viewport", "target", "at_end" }) |name| {
            _ = @FieldType(Cx.ScrollPosition, name);
        }
        _ = @as(Cx.ScrollPosition.Target, .end);
        // Opaque: no field, `window` included, is reachable from a `*Cx`.
        if (@typeInfo(Cx) != .@"opaque") @compileError("gooey.Cx must stay opaque");
        // A `Painter` exposes only the paint element's bounds.
        if (@typeInfo(gooey.Painter).@"struct".field_names.len != 1) {
            @compileError("gooey.Painter must carry only its bounds");
        }
        _ = @FieldType(gooey.Painter, "bounds");
    }
}

/// The exact public names of the root and its namespaces: one missing or
/// one extra fails with the namespace and both lists.
fn pinExact() void {
    comptime {
        expectDecls(gooey, "gooey", &.{
            "App",         "Config",            "Init",              "Job",
            "JobId",       "Cx",                "ui",                "Handler",
            "Effects",     "Entity",            "ElementId",         "Key",
            "Lifetime",    "Handle",            "Drag",              "Theme",
            "Painter",     "PathPromptOptions", "SavePromptOptions", "Paths",
            "InputEngine", "AreaEngine",        "EditorEngine",      "ResourceLimits",
            "FontLimits",  "FontSource",        "Color",             "animation",
            "input",       "text",              "accessibility",     "log",
            "std_options", "testing",           "internals",
        });
        expectDecls(gooey.ui, "gooey.ui", &.{
            "box",          "text",          "paint",           "Paint",        "when",
            "action",       "Box",           "Style",           "Direction",    "Layer",
            "Anchor",       "Scroll",        "ClipPolicy",      "CursorShape",  "PointerEvents",
            "KeyContext",   "ActionBinding", "DragSource",      "DropTarget",   "Text",
            "Sizing",       "Edges",         "Corners",         "Alignment",    "Border",
            "Shadow",       "ColorToken",    "Color",           "A11y",         "Role",
            "Orientation",  "HeadingLevel",  "Painter",         "PaintText",    "PaintSvg",
            "PaintImage",   "ObjectFit",     "Rect",            "ScrollAnchor", "ScrollTarget",
            "ScrollOffset", "ScrollChild",   "ScrollAlignment",
        });
        expectDecls(gooey.Cx, "gooey.Cx", &.{
            "ScrollPosition", "state",   "theme",              "fontMetrics", "id",
            "hovered",        "focused", "requestRenderAfter", "now",         "limits",
            "bounds",         "scroll",  "drag",               "on",          "retain",
            "get",            "release", "render",
        });
        expectDecls(gooey.text, "gooey.text", &.{
            "Metrics",     "FontWeight",     "FontFamily",
            "FontVariant", "codepointCount", "run_codepoint_count_max",
        });
        expectDecls(gooey.accessibility, "gooey.accessibility", &.{
            "Role", "State", "Live", "HeadingLevel", "Orientation",
        });
        expectDecls(gooey.input, "gooey.input", &.{
            "events",             "InputEvent",       "MouseEvent",     "MouseButton",
            "ScrollEvent",        "KeyEvent",         "KeyCode",        "Modifiers",
            "TextInputEvent",     "CompositionEvent", "FocusLostEvent", "HeldKeys",
            "held_key_count_max", "Keystroke",
        });
        expectDecls(gooey.animation, "gooey.animation", &.{
            "tween_duration_ms_max", "Easing", "Tween",   "Spring", "Phase",
            "Motion",                "tween",  "tweenOn", "motion",
        });
    }
}

fn expectDecls(
    comptime T: type,
    comptime name: []const u8,
    comptime names: []const []const u8,
) void {
    // Each name is compared with every pinned one: at most 40 by 40 here.
    @setEvalBranchQuota(100_000);
    const decls = switch (@typeInfo(T)) {
        .@"struct" => |info| info.decl_names,
        .@"opaque" => |info| info.decl_names,
        else => @compileError(name ++ " is not a namespace"),
    };
    for (names) |expected| {
        if (!@hasDecl(T, expected)) {
            @compileError(name ++ " lost pinned name '" ++ expected ++ "'");
        }
    }
    for (decls) |actual| {
        for (names) |expected| {
            if (std.mem.eql(u8, actual, expected)) break;
        } else @compileError(name ++ " has unpinned public name '" ++ actual ++
            "': pin it in src/api_check.zig or make it private");
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
        pinExact();
    }
}
