//! gooey - A minimal GPU-accelerated UI framework for Zig
//!
//! Inspired by GPUI, targeting macOS with Metal rendering.
//!
//! ## Module Organization
//!
//! Gooey is organized into logical namespaces:
//!
//! - `core` - Geometry, input, scene primitives, events
//! - `layout` - Clay-inspired layout engine
//! - `text` - Text rendering with backend abstraction
//! - `ui` - Declarative component builder
//! - `platform` - Platform abstraction (macOS/Metal currently)
//! - `elements` - Reusable widgets (TextInput, etc.)
//!
//! ## Quick Start
//!
//! For simple apps, use the convenience exports at the top level:
//!
//! ```zig
//! const gooey = @import("gooey");
//!
//! pub fn main() !void {
//!     try gooey.run(.{
//!         .title = "My App",
//!         .render = render,
//!     });
//! }
//!
//! fn render(ui: *gooey.UI) void {
//!     ui.vstack(.{ .gap = 16 }, .{
//!         gooey.ui.text("Hello, gooey!", .{}),
//!     });
//! }
//! ```
//!
//! ## Explicit Imports
//!
//! For larger apps, use the namespaced modules:
//!
//! ```zig
//! const gooey = @import("gooey");
//! const Color = gooey.core.Color;
//! const LayoutEngine = gooey.layout.LayoutEngine;
//! const TextSystem = gooey.text.TextSystem;
//! ```

const std = @import("std");

// =============================================================================
// Module Namespaces (for explicit imports)
// =============================================================================

/// Core primitives: geometry, input, scene, events
pub const core = @import("core/mod.zig");

/// Layout engine (Clay-inspired)
pub const layout = @import("layout/layout.zig");

/// Text rendering system with backend abstraction
pub const text = @import("text/mod.zig");

/// Declarative UI builder
pub const ui = @import("ui/mod.zig");

/// Platform abstraction (macOS/Metal)
pub const platform = @import("platform/mod.zig");

// Components (preferred)
pub const components = @import("components/mod.zig");
pub const Button = components.Button;
pub const Checkbox = components.Checkbox;
pub const TextInput = components.TextInput;
pub const TextArea = components.TextArea;
pub const ProgressBar = components.ProgressBar;
pub const RadioGroup = components.RadioGroup;
pub const RadioButton = components.RadioButton;
pub const Tab = components.Tab;
pub const TabBar = components.TabBar;

// =============================================================================
// App Entry Point (most common usage)
// =============================================================================

pub const app = @import("app.zig");

// =============================================================================
// Convenience Exports (backward compatible, for quick prototyping)
// =============================================================================

// Geometry (most commonly used)
pub const Color = core.Color;
pub const Point = core.Point;
pub const Size = core.Size;
pub const Rect = core.Rect;
pub const Bounds = core.Bounds;
pub const PointF = core.PointF;
pub const SizeF = core.SizeF;
pub const BoundsF = core.BoundsF;
pub const Edges = core.Edges;
pub const Corners = core.Corners;
pub const Pixels = core.Pixels;

// Input events
pub const InputEvent = core.InputEvent;
pub const KeyEvent = core.KeyEvent;
pub const KeyCode = core.KeyCode;
pub const MouseEvent = core.MouseEvent;
pub const MouseButton = core.MouseButton;
pub const Modifiers = core.Modifiers;

// Scene primitives
pub const Scene = core.Scene;
pub const Quad = core.Quad;
pub const Shadow = core.Shadow;
pub const Hsla = core.Hsla;
pub const GlyphInstance = core.GlyphInstance;

// SVG support
pub const svg = core.svg;
pub const tessellator = core.tessellator;
pub const svg_mesh = core.svg_mesh;
pub const SvgMesh = core.SvgMesh;
pub const SvgInstance = core.SvgInstance;

// Render bridge
pub const render_bridge = core.render_bridge;

// Event system
pub const Event = core.Event;
pub const EventPhase = core.EventPhase;
pub const EventResult = core.EventResult;

// Element types
pub const ElementId = core.ElementId;

// Gooey context
pub const Gooey = core.Gooey;
pub const WidgetStore = core.WidgetStore;

// Layout (commonly used types)
pub const LayoutEngine = layout.LayoutEngine;
pub const LayoutId = layout.LayoutId;
pub const Sizing = layout.Sizing;
pub const Padding = layout.Padding;
pub const LayoutConfig = layout.LayoutConfig;
pub const BoundingBox = layout.BoundingBox;

// Focus system
pub const FocusId = core.FocusId;
pub const FocusHandle = core.FocusHandle;
pub const FocusManager = core.FocusManager;
pub const FocusEvent = core.FocusEvent;

// =============================================================================
// Cx API (Unified Context - Recommended)
// =============================================================================

/// The unified rendering context
pub const Cx = app.Cx;

/// Run an app with the unified Cx context (recommended for stateful apps)
pub const runCx = app.runCx;

/// Web app generator (for WASM targets)
pub const WebApp = app.WebApp;
/// Unified app generator (works for native and web)
pub const App = app.App;

/// Configuration for runCx
pub const CxConfig = app.CxConfig;

// Custom shaders
pub const CustomShader = core.CustomShader;

// Entity system
pub const Entity = core.Entity;
pub const EntityId = core.EntityId;
pub const EntityMap = core.EntityMap;
pub const EntityContext = core.EntityContext;
pub const isView = core.isView;

// Handler system
pub const HandlerRef = core.HandlerRef;

// Animation system
pub const Animation = core.Animation;
pub const AnimationHandle = core.AnimationHandle;
pub const Easing = core.Easing;
pub const Duration = core.Duration;
pub const animation = core.animation;
pub const lerp = core.lerp;
pub const lerpInt = core.lerpInt;
pub const lerpColor = core.lerpColor;

// Text system
pub const TextSystem = text.TextSystem;
pub const FontFace = text.FontFace;
pub const TextMeasurement = text.TextMeasurement;

// UI builder
pub const Builder = ui.Builder;

// Platform (for direct access)
pub const MacPlatform = platform.Platform;
pub const Window = platform.Window;
// Platform interfaces (for runtime polymorphism)
pub const PlatformVTable = platform.PlatformVTable;
pub const WindowVTable = platform.WindowVTable;
pub const PlatformCapabilities = platform.PlatformCapabilities;
pub const WindowOptions = platform.WindowOptions;
pub const RendererCapabilities = platform.RendererCapabilities;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
