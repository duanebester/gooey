//! Core primitives and shared types for gooey
//!
//! This module contains the foundational types used throughout gooey:
//! - Geometry types (Point, Size, Rect, Color)
//! - Input events (keyboard, mouse)
//! - Scene primitives (Quad, Shadow, Glyph)
//! - Event system
//! - Render bridge (layout -> scene conversion)
//!
//! ## Architecture
//!
//! The core module is designed to have minimal dependencies and serve as
//! the foundation for all other gooey modules.

const std = @import("std");

// =============================================================================
// Geometry (platform-agnostic primitives)
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
// Input Events
// =============================================================================

pub const input = @import("input.zig");

pub const InputEvent = input.InputEvent;
pub const MouseEvent = input.MouseEvent;
pub const MouseButton = input.MouseButton;
pub const KeyEvent = input.KeyEvent;
pub const KeyCode = input.KeyCode;
pub const Modifiers = input.Modifiers;

// =============================================================================
// Scene (GPU primitives)
// =============================================================================

pub const scene = @import("scene.zig");

pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const Hsla = scene.Hsla;
pub const GlyphInstance = scene.GlyphInstance;

// =============================================================================
// SVG Support
// =============================================================================

pub const svg = @import("svg.zig");
pub const tessellator = @import("tessellator.zig");
pub const svg_mesh = @import("svg_mesh.zig");

pub const SvgMesh = svg_mesh.SvgMesh;
pub const SvgInstance = svg_mesh.SvgInstance;

// =============================================================================
// Render Bridge (layout -> scene conversion)
// =============================================================================

pub const render_bridge = @import("render_bridge.zig");

pub const colorToHsla = render_bridge.colorToHsla;
pub const renderCommandsToScene = render_bridge.renderCommandsToScene;

// =============================================================================
// Event System
// =============================================================================

pub const event = @import("event.zig");

pub const Event = event.Event;
pub const EventPhase = event.EventPhase;
pub const EventResult = event.EventResult;

// =============================================================================
// Action System
// =============================================================================

pub const action = @import("action.zig");

pub const Keymap = action.Keymap;
pub const Keystroke = action.Keystroke;
pub const KeyBinding = action.KeyBinding;
pub const actionTypeId = action.actionTypeId;

// =============================================================================
// Context System
// =============================================================================

// pub const context = @import("context.zig");
// pub const Context = context.Context;

// Handler
pub const handler = @import("handler.zig");
pub const HandlerRef = handler.HandlerRef;

// =============================================================================
// Entity System
// =============================================================================

pub const entity = @import("entity.zig");
pub const Entity = entity.Entity;
pub const EntityId = entity.EntityId;
pub const EntityMap = entity.EntityMap;
pub const EntityContext = entity.EntityContext;
pub const isView = entity.isView;

// =============================================================================
// Focus System
// =============================================================================

pub const focus = @import("focus.zig");

pub const FocusManager = focus.FocusManager;
pub const FocusId = focus.FocusId;
pub const FocusHandle = focus.FocusHandle;
pub const FocusEvent = focus.FocusEvent;

// =============================================================================
// Element Types
// =============================================================================

pub const element_types = @import("element_types.zig");

pub const ElementId = element_types.ElementId;

// =============================================================================
// Gooey Context & Widget Store
// =============================================================================

pub const gooey = @import("gooey.zig");
pub const Gooey = gooey.Gooey;

pub const widget_store = @import("widget_store.zig");
pub const WidgetStore = widget_store.WidgetStore;

// =============================================================================
// Render Stats (performance monitoring)
// =============================================================================

pub const render_stats = @import("render_stats.zig");
pub const RenderStats = render_stats.RenderStats;

// =============================================================================
// Animation System
// =============================================================================

pub const animation = @import("animation.zig");

pub const Animation = animation.AnimationConfig;
pub const AnimationHandle = animation.AnimationHandle;
pub const AnimationState = animation.AnimationState;
pub const Easing = animation.Easing;
pub const Duration = animation.Duration;
pub const lerp = animation.lerp;
pub const lerpInt = animation.lerpInt;
pub const lerpColor = animation.lerpColor;

// =============================================================================
// Custom Shaders
// =============================================================================

pub const shader = @import("shader.zig");
pub const CustomShader = shader.CustomShader;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
