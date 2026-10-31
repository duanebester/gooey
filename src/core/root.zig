//! The 0.4.0 core's public surface (contract "Shape"): `App`, `Cx`, `ui`,
//! `Handler`, `ElementId`, and `ResourceLimits`.
//!
//! The core runs beside the 0.3.1 middle until phase 6 deletes the middle;
//! until then it is reached as `gooey.core`.

const std = @import("std");

pub const id = @import("id.zig");
pub const records = @import("records.zig");
pub const handler = @import("handler.zig");
pub const events = @import("events.zig");
pub const element = @import("element.zig");
pub const cx = @import("cx.zig");
pub const retained = @import("retained.zig");
pub const router = @import("router.zig");
pub const layers = @import("layers.zig");
pub const tick = @import("tick.zig");
pub const app = @import("app.zig");
pub const emit = @import("emit.zig");
pub const pack = @import("pack.zig");
pub const window = @import("window.zig");
pub const lifecycle = @import("lifecycle.zig");
pub const text_engine = @import("text_engine.zig");

pub const App = app.App;
pub const Config = app.Config;
pub const Cx = cx.Cx;
pub const Handler = handler.Handler;
pub const Effects = handler.Effects;
pub const Entity = handler.Entity;
pub const ElementId = id.ElementId;
pub const Key = id.Key;
pub const Lifetime = retained.Lifetime;
pub const Handle = retained.Handle;
pub const Query = router.Query;
pub const Theme = element.Theme;
pub const Painter = emit.Painter;
pub const InputEngine = text_engine.InputEngine;
pub const AreaEngine = text_engine.AreaEngine;
pub const ResourceLimits = @import("limits.zig").ResourceLimits;
pub const FontLimits = app.FontLimits;
pub const FontSource = app.FontSource;

/// Element constructors and their types: `ui.box`, `ui.text`, `ui.paint`,
/// `ui.when`, and `ui.Style`.
pub const ui = struct {
    pub const box = element.box;
    pub const text = element.text;
    pub const paint = element.paint;
    pub const when = element.when;
    pub const action = element.action;
    pub const Box = element.Box;
    pub const Style = element.Style;
    pub const Text = element.Text;
    pub const Sizing = element.Sizing;
    pub const Edges = element.Edges;
    pub const Corners = element.Corners;
    pub const Alignment = element.Alignment;
    pub const Border = element.Border;
    pub const Shadow = element.Shadow;
    pub const ColorToken = element.ColorToken;
    pub const Color = element.Color;
    pub const A11y = element.A11y;
    pub const Role = element.Role;
    pub const Painter = emit.Painter;
    pub const PaintText = emit.TextStyle;
    pub const PaintSvg = emit.SvgStyle;
    pub const Rect = records.Rect;
};

test {
    std.testing.refAllDecls(@This());
    _ = id;
    _ = records;
    _ = handler;
    _ = events;
    _ = element;
    _ = retained;
    _ = text_engine;
    _ = lifecycle;
    _ = layers;
    _ = @import("screen_reader.zig");
    _ = @import("keymap.zig");
    _ = @import("clipboard.zig");
    _ = @import("text_history.zig");
}
