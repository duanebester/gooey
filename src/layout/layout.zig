//! Layout system module - Clay-inspired declarative layout for gooey

const std = @import("std");

// Sub-modules
pub const types = @import("types.zig");
pub const arena = @import("arena.zig");
pub const engine = @import("engine.zig");
pub const sizing_pass = @import("sizing_pass.zig");
pub const position_pass = @import("position_pass.zig");

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

pub const LayoutArena = arena.LayoutArena;

// Element types from engine (no separate element.zig needed)
pub const ElementDeclaration = engine.ElementDeclaration;
pub const LayoutElement = engine.LayoutElement;
pub const ElementType = engine.ElementType;
pub const TextData = engine.TextData;

pub const LayoutEngine = engine.LayoutEngine;
pub const MeasureTextFn = engine.MeasureTextFn;

// Anchor for test discovery: refAllDecls walks the `pub const`s above,
// reaching the per-pass test bodies; the engine test files are imported
// explicitly below.
test {
    std.testing.refAllDecls(@This());
    _ = @import("engine_tests.zig");
    _ = @import("engine_internal_tests.zig");
}
