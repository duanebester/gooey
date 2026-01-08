//! Core primitives and shared types for gooey
//!
//! This module contains the foundational types used throughout gooey:
//! - Geometry types (Point, Size, Rect, Color)
//! - Input events (keyboard, mouse) - re-exported from `input` module
//! - Scene primitives (Quad, Shadow, Glyph) - re-exported from `scene` module
//! - Event system
//! - Render bridge (layout -> scene conversion)
//!
//! ## Architecture
//!
//! The core module is designed to have minimal dependencies and serve as
//! the foundation for all other gooey modules. Many types are re-exported
//! from their canonical locations in other modules for backward compatibility.

const std = @import("std");

// =============================================================================
// Geometry (platform-agnostic primitives) - LOCAL
// =============================================================================

pub const geometry = @import("geometry.zig");

// Generic types
pub const Point = geometry.Point;
pub const Size = geometry.Size;
pub const Rect = geometry.Rect;
pub const Bounds = geometry.Bounds;
pub const Edges = geometry.Edges;
pub const Corners = geometry.Corners;
pub const Color = geometry.Color;

// Concrete type aliases
pub const PointF = geometry.PointF;
pub const PointI = geometry.PointI;
pub const SizeF = geometry.SizeF;
pub const SizeI = geometry.SizeI;
pub const RectF = geometry.RectF;
pub const RectI = geometry.RectI;
pub const BoundsF = geometry.BoundsF;
pub const BoundsI = geometry.BoundsI;
pub const EdgesF = geometry.EdgesF;
pub const CornersF = geometry.CornersF;

// GPU-aligned types
pub const GpuPoint = geometry.GpuPoint;
pub const GpuSize = geometry.GpuSize;
pub const GpuBounds = geometry.GpuBounds;
pub const GpuCorners = geometry.GpuCorners;
pub const GpuEdges = geometry.GpuEdges;

// Unit aliases
pub const Pixels = geometry.Pixels;

// =============================================================================
// Input Events - RE-EXPORTED from input module
// =============================================================================

pub const input = @import("../input/mod.zig");

pub const InputEvent = input.InputEvent;
pub const MouseEvent = input.MouseEvent;
pub const MouseButton = input.MouseButton;
pub const KeyEvent = input.KeyEvent;
pub const KeyCode = input.KeyCode;
pub const Modifiers = input.Modifiers;
pub const TextInputEvent = input.TextInputEvent;
pub const CompositionEvent = input.CompositionEvent;
pub const ScrollEvent = input.ScrollEvent;

// =============================================================================
// Scene (GPU primitives) - RE-EXPORTED from scene module
// =============================================================================

pub const scene = @import("../scene/mod.zig");

pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const Hsla = scene.Hsla;
pub const GlyphInstance = scene.GlyphInstance;
pub const SvgInstance = scene.SvgInstance;
pub const ImageInstance = scene.ImageInstance;
pub const DrawOrder = scene.DrawOrder;
pub const ContentMask = scene.ContentMask;

// =============================================================================
// Batch Iterator - RE-EXPORTED from scene module
// =============================================================================

pub const batch_iterator = scene.batch_iterator;

pub const BatchIterator = scene.BatchIterator;
pub const PrimitiveBatch = scene.PrimitiveBatch;
pub const PrimitiveKind = scene.PrimitiveKind;

// =============================================================================
// SVG Support - LOCAL
// =============================================================================

pub const svg = @import("svg.zig");

// =============================================================================
// Render Bridge (layout -> scene conversion) - LOCAL
// =============================================================================

pub const render_bridge = @import("render_bridge.zig");

pub const colorToHsla = render_bridge.colorToHsla;
pub const renderCommandsToScene = render_bridge.renderCommandsToScene;

// =============================================================================
// Event System - LOCAL
// =============================================================================

pub const event = @import("event.zig");

pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;

// =============================================================================
// Action System - RE-EXPORTED from input module
// =============================================================================

pub const action = input.actions;

pub const Keymap = input.Keymap;
pub const Keystroke = input.Keystroke;
pub const KeyBinding = input.KeyBinding;
pub const actionTypeId = input.actionTypeId;

// =============================================================================
// Context System - RE-EXPORTED from context module
// =============================================================================

pub const context = @import("../context/mod.zig");

// Handler
pub const handler = context.handler;
pub const HandlerRef = context.HandlerRef;

// =============================================================================
// Entity System - RE-EXPORTED from context module
// =============================================================================

pub const entity = context.entity;
pub const Entity = context.Entity;
pub const EntityId = context.EntityId;
pub const EntityMap = context.EntityMap;
pub const EntityContext = context.EntityContext;
pub const isView = context.isView;

// =============================================================================
// Focus System - RE-EXPORTED from context module
// =============================================================================

pub const focus = context.focus;

pub const FocusManager = context.FocusManager;
pub const FocusId = context.FocusId;
pub const FocusHandle = context.FocusHandle;
pub const FocusEvent = context.FocusEvent;

// =============================================================================
// Element Types - LOCAL
// =============================================================================

pub const element_types = @import("element_types.zig");

pub const ElementId = element_types.ElementId;

// =============================================================================
// Gooey Context & Widget Store - RE-EXPORTED from context module
// =============================================================================

pub const gooey = context.gooey;
pub const Gooey = context.Gooey;

pub const widget_store = context.widget_store;
pub const WidgetStore = context.WidgetStore;

// =============================================================================
// Render Stats - RE-EXPORTED from debug module
// =============================================================================

pub const debug = @import("../debug/mod.zig");

pub const render_stats = debug.render_stats;
pub const RenderStats = debug.RenderStats;

// =============================================================================
// Debugger/Inspector - RE-EXPORTED from debug module
// =============================================================================

pub const debugger = debug.debugger;
pub const Debugger = debug.Debugger;
pub const DebugMode = debug.DebugMode;

// =============================================================================
// Animation System - RE-EXPORTED from animation module
// =============================================================================

pub const animation = @import("../animation/mod.zig");

pub const Animation = animation.Animation;
pub const AnimationHandle = animation.AnimationHandle;
pub const AnimationState = animation.AnimationState;
pub const Easing = animation.Easing;
pub const Duration = animation.Duration;
pub const lerp = animation.lerp;
pub const lerpInt = animation.lerpInt;
pub const lerpColor = animation.lerpColor;

// =============================================================================
// Custom Shaders - LOCAL
// =============================================================================

pub const shader = @import("shader.zig");
pub const CustomShader = shader.CustomShader;

// =============================================================================
// Triangulator - LOCAL
// =============================================================================

pub const triangulator = @import("triangulator.zig");
pub const Triangulator = triangulator.Triangulator;
pub const Vec2 = triangulator.Vec2;
pub const IndexSlice = triangulator.IndexSlice;

// =============================================================================
// Path Builder API - LOCAL
// =============================================================================

pub const path = @import("path.zig");
pub const Path = path.Path;
pub const PathCommand = path.Command;
pub const PathError = path.PathError;

// =============================================================================
// Stroke API - LOCAL
// =============================================================================

pub const stroke = @import("stroke.zig");
pub const LineCap = stroke.LineCap;
pub const LineJoin = stroke.LineJoin;
pub const StrokeStyle = stroke.StrokeStyle;
pub const StrokeError = stroke.StrokeError;

// =============================================================================
// Gradient API - LOCAL
// =============================================================================

pub const gradient = @import("gradient.zig");
pub const Gradient = gradient.Gradient;
pub const GradientType = gradient.GradientType;
pub const GradientStop = gradient.GradientStop;
pub const LinearGradient = gradient.LinearGradient;
pub const RadialGradient = gradient.RadialGradient;

// =============================================================================
// Path Types - RE-EXPORTED from scene module
// =============================================================================

pub const PathInstance = scene.PathInstance;
pub const PathMesh = scene.PathMesh;
pub const PathVertex = scene.PathVertex;
pub const MeshPool = scene.MeshPool;
pub const MeshRef = scene.MeshRef;

// =============================================================================
// Path Rendering Limits - LOCAL
// =============================================================================

pub const limits = @import("limits.zig");

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
