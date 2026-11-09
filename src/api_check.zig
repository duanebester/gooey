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
        _ = gooey.ui.Text;
        _ = gooey.ui.Color;
        _ = gooey.ui.A11y;
        _ = gooey.ui.Painter;
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
    }
}

/// `Cx`'s most-used methods: every render function calls these.
fn pinCx() void {
    comptime {
        _ = @TypeOf(gooey.Cx.state);
        _ = @TypeOf(gooey.Cx.render);
        _ = @TypeOf(gooey.Cx.on);
        _ = @TypeOf(gooey.Cx.theme);
    }
}

test "public API surface compiles" {
    comptime {
        pinSurface();
        pinUi();
        pinNamespaces();
        pinCx();
    }
}
