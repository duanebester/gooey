//! gooey - A minimal GPU-accelerated UI framework for Zig
//!
//! Inspired by GPUI, targeting macOS with Metal rendering.
//!
//! ## Module Organization
//!
//! Gooey is organized into logical namespaces:
//!
//! - `core` - Foundational types (geometry, color)
//! - `input` - Input events, keycodes, action bindings
//! - `scene` - GPU primitives (Quad, Shadow, GlyphInstance)
//! - `context` - Application context (Gooey, focus, dispatch, entity)
//! - `animation` - Animation system (easing, interpolation)
//! - `layout` - Clay-inspired layout engine
//! - `text` - Text rendering with backend abstraction
//! - `ui` - Declarative UI builder and primitives
//! - `components` - High-level UI components (Button, TextInput, etc.)
//! - `widgets` - Stateful widget implementations
//! - `platform` - Platform abstraction (macOS/Metal, Linux/Vulkan, Web/WGPU)
//! - `debug` - Debugging tools (inspector, profiler, render stats)
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

/// Core primitives: geometry, color (foundational types with no internal deps)
pub const core = @import("core/mod.zig");

/// Input system: events, keycodes, action bindings
pub const input = @import("input/mod.zig");

/// Scene: GPU primitives for rendering
pub const scene = @import("scene/mod.zig");

/// Context: application context, focus, dispatch, entity system
pub const context = @import("context/mod.zig");

/// Animation: time-based interpolation for UI transitions
pub const animation = @import("animation/mod.zig");

/// Debug tools: inspector, profiler, render stats
pub const debug = @import("debug/mod.zig");

/// Layout engine (Clay-inspired)
pub const layout = @import("layout/layout.zig");

/// Text rendering system with backend abstraction
pub const text = @import("text/mod.zig");

/// Declarative UI builder
pub const ui = @import("ui/mod.zig");

/// Platform abstraction (macOS/Metal, Linux/Vulkan, Web/WGPU)
pub const platform = @import("platform/mod.zig");

/// Image loading and caching
pub const image = @import("image/mod.zig");

/// Stateful widget implementations
pub const widgets = @import("widgets/mod.zig");

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
pub const Svg = components.Svg;
pub const Icons = components.Icons;
pub const Select = components.Select;
pub const Image = components.Image;
pub const AspectRatio = components.AspectRatio;
pub const Tooltip = components.Tooltip;
pub const Modal = components.Modal;

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

// Input events (types from core for convenience)
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

// Image support
pub const ImageAtlas = image.ImageAtlas;
pub const ImageSource = image.ImageSource;
pub const ImageData = image.ImageData;
pub const ObjectFit = image.ObjectFit;

// WASM async image loader (only available on WASM targets)
pub const wasm_image_loader = if (platform.is_wasm)
    @import("platform/wgpu/web/image_loader.zig")
else
    struct {
        pub const DecodedImage = struct {
            width: u32,
            height: u32,
            pixels: []u8,
            owned: bool,
            pub fn deinit(_: *@This(), _: @import("std").mem.Allocator) void {}
        };
        pub const DecodeCallback = *const fn (u32, ?DecodedImage) void;
        pub fn init(_: @import("std").mem.Allocator) void {}
        pub fn loadFromUrlAsync(_: []const u8, _: DecodeCallback) ?u32 {
            return null;
        }
        pub fn loadFromMemoryAsync(_: []const u8, _: DecodeCallback) ?u32 {
            return null;
        }
    };

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
pub const CornerRadius = layout.CornerRadius;
pub const LayoutConfig = layout.LayoutConfig;
pub const BoundingBox = layout.BoundingBox;

// Virtual list (for large datasets)
pub const UniformListState = widgets.UniformListState;
pub const VirtualListState = widgets.VirtualListState;
pub const VisibleRange = widgets.VisibleRange;
pub const ScrollStrategy = widgets.ScrollStrategy;

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
pub const typeId = context.typeId;

// Animation system (types from animation module for convenience)
pub const Animation = animation.Animation;
pub const AnimationHandle = animation.AnimationHandle;
pub const Easing = animation.Easing;
pub const Duration = animation.Duration;
pub const lerp = animation.lerp;
pub const lerpInt = animation.lerpInt;
pub const lerpColor = animation.lerpColor;

// Text system
pub const TextSystem = text.TextSystem;
pub const FontFace = text.FontFace;
pub const TextMeasurement = text.TextMeasurement;

// UI builder
pub const Builder = ui.Builder;

// Theme system
pub const Theme = ui.Theme;

// UI style types
pub const Box = ui.Box;
pub const StackStyle = ui.StackStyle;
pub const CenterStyle = ui.CenterStyle;
pub const ScrollStyle = ui.ScrollStyle;
pub const UniformListStyle = ui.UniformListStyle;
pub const VirtualListStyle = ui.VirtualListStyle;
pub const InputStyle = ui.InputStyle;
pub const TextAreaStyle = ui.TextAreaStyle;

// Platform (for direct access)
pub const MacPlatform = platform.Platform;
pub const Window = platform.Window;
// Platform interfaces (for runtime polymorphism)
pub const PlatformVTable = platform.PlatformVTable;
pub const WindowVTable = platform.WindowVTable;
pub const PlatformCapabilities = platform.PlatformCapabilities;
pub const WindowOptions = platform.WindowOptions;
pub const RendererCapabilities = platform.RendererCapabilities;

// File dialogs
pub const PathPromptOptions = platform.PathPromptOptions;
pub const PathPromptResult = platform.PathPromptResult;
pub const SavePromptOptions = platform.SavePromptOptions;

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
