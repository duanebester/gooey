//! Layout system module - Clay-inspired declarative layout for gooey

const std = @import("std");

// Sub-modules
pub const types = @import("types.zig");
pub const layout_id = @import("layout_id.zig");
pub const arena = @import("arena.zig");
pub const render_commands = @import("render_commands.zig");
pub const engine = @import("engine.zig");
pub const sizing_pass = @import("sizing_pass.zig");
pub const position_pass = @import("position_pass.zig");
pub const scroll_pass = @import("scroll_pass.zig");

// Re-export commonly used types
pub const Sizing = types.Sizing;
pub const SizingAxis = types.SizingAxis;
pub const SizingType = types.SizingType;
pub const LayoutConfig = types.LayoutConfig;
pub const LayoutDirection = types.LayoutDirection;
pub const Padding = types.Padding;
pub const ChildAlignment = types.ChildAlignment;
pub const AlignmentX = types.AlignmentX;
pub const AlignmentY = types.AlignmentY;
pub const MainAxisDistribution = types.MainAxisDistribution;
pub const Color = types.Color;
pub const CornerRadius = types.CornerRadius;
pub const BorderConfig = types.BorderConfig;
pub const BorderWidth = types.BorderWidth;
pub const ShadowConfig = types.ShadowConfig;
pub const FloatingConfig = types.FloatingConfig;
pub const ScrollConfig = types.ScrollConfig;
pub const TextConfig = types.TextConfig;
pub const BoundingBox = types.BoundingBox;
pub const AttachPoint = types.AttachPoint;

pub const LayoutId = layout_id.LayoutId;
pub const LayoutArena = arena.LayoutArena;

// Element types from engine (no separate element.zig needed)
pub const ElementDeclaration = engine.ElementDeclaration;
pub const LayoutElement = engine.LayoutElement;
pub const ElementType = engine.ElementType;
pub const TextData = engine.TextData;
pub const SourceLoc = engine.SourceLoc;

pub const RenderCommand = render_commands.RenderCommand;
pub const RenderCommandType = render_commands.RenderCommandType;
pub const RenderCommandList = render_commands.RenderCommandList;
pub const RenderData = render_commands.RenderData;

// NOTE: colorToHsla and renderCommandsToScene have been moved to
// core/render_bridge.zig to decouple layout from scene rendering

pub const LayoutEngine = engine.LayoutEngine;
pub const MeasureTextFn = engine.MeasureTextFn;

// Anchor for test discovery: refAllDecls walks every `pub const`
// above (which is how the per-pass test bodies and the engine tests
// are reached at `zig build test`). The dedicated test files live
// next to their production code so the per-pass write scope holds.
test {
    std.testing.refAllDecls(@This());
    _ = @import("engine_tests.zig");
    _ = @import("engine_internal_tests.zig");
}
