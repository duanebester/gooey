//! gooey - A minimal GPU-accelerated UI framework for Zig
//! Inspired by GPUI, targeting macOS with Metal rendering.

const std = @import("std");

// Re-export core types
pub const geometry = @import("core/geometry.zig");
pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Color = geometry.Color;

// Input events
pub const input = @import("core/input.zig");
pub const InputEvent = input.InputEvent;
pub const MouseEvent = input.MouseEvent;
pub const MouseButton = input.MouseButton;

// Scene and primitives
pub const scene = @import("core/scene.zig");
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const Hsla = scene.Hsla;
pub const GlyphInstance = scene.GlyphInstance;

// Font system
pub const font = @import("font/main.zig");
pub const TextSystem = font.TextSystem;
pub const Face = font.Face;
pub const TextStyle = font.TextStyle;

// Re-export platform types
pub const platform = @import("platform/mac/platform.zig");
pub const MacPlatform = platform.MacPlatform;
pub const Window = @import("platform/mac/window.zig").Window;
pub const DisplayLink = @import("platform/mac/display_link.zig").DisplayLink;

// App context
pub const App = @import("core/app.zig").App;

// UI Elements
pub const elements = @import("elements.zig");
pub const TextInput = elements.TextInput;

// Element system
pub const element = @import("core/element.zig");
pub const Element = element.Element;
pub const ElementId = element.ElementId;
pub const asElement = element.asElement;

// Entity system (for reactive state management)
pub const entity = @import("core/entity.zig");
pub const EntityId = entity.EntityId;
pub const Entity = entity.Entity;
pub const WeakEntity = entity.WeakEntity;
pub const AnyEntity = entity.AnyEntity;
pub const AnyWeakEntity = entity.AnyWeakEntity;
pub const RefCounts = entity.RefCounts;

// Entity map
pub const entity_map = @import("core/entity_map.zig");
pub const EntityMap = entity_map.EntityMap;

// Context system (for reactive updates)
pub const context = @import("core/context.zig");
pub const Context = context.Context;

// Render system (for views)
pub const render = @import("core/render.zig");
pub const Renderable = render.Renderable;
pub const ViewContext = render.ViewContext;
pub const AnyView = render.AnyView;
pub const AnyWeakView = render.AnyWeakView;
pub const RenderOutput = render.RenderOutput;
pub const Listener = render.Listener;
pub const WindowVTable = render.WindowVTable;

// Event system
pub const event = @import("core/event.zig");
pub const Event = event.Event;
pub const EventPhase = event.EventPhase;

// Layout system
pub const layout = @import("layout/layout.zig");
pub const LayoutEngine = layout.LayoutEngine;
pub const LayoutId = layout.LayoutId;
pub const Sizing = layout.Sizing;
pub const LayoutConfig = layout.LayoutConfig;
pub const ElementDeclaration = layout.ElementDeclaration;
pub const BoundingBox = layout.BoundingBox;

// View tree
pub const view = @import("core/view.zig");
pub const ViewTree = view.ViewTree;

test {
    std.testing.refAllDecls(@This());
}
