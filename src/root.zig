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
const builtin = @import("builtin");

// =============================================================================
// WASM-compatible logging
// =============================================================================

/// WASM-compatible log function for use with std_options.
/// WASM executables should define in their root file:
/// ```
/// pub const std_options: std.Options = .{
///     .logFn = gooey.wasmLogFn,
/// };
/// ```
pub fn wasmLogFn(
    comptime level: std.log.Level,
    comptime scope: @Type(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    const web_imports = @import("platform/web/imports.zig");
    const prefix = switch (level) {
        .err => "[error] ",
        .warn => "[warn] ",
        .info => "[info] ",
        .debug => "[debug] ",
    };
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, prefix ++ format, args) catch return;
    if (level == .err) {
        web_imports.consoleError(msg.ptr, @intCast(msg.len));
    } else {
        web_imports.consoleLog(msg.ptr, @intCast(msg.len));
    }
}

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

/// Form validation utilities (pure functions)
pub const validation = @import("validation.zig");

/// Accessibility (A11Y) - screen reader and assistive technology support
pub const accessibility = @import("accessibility/mod.zig");

/// AI integration: canvas command buffer for LLM-driven drawing
pub const ai = @import("ai/mod.zig");

/// Text rendering system with backend abstraction
pub const text = @import("text/mod.zig");

/// Declarative UI builder
pub const ui = @import("ui/mod.zig");

/// Platform abstraction (macOS/Metal, Linux/Vulkan, Web/WGPU)
pub const platform = @import("platform/mod.zig");

/// Runtime: event loop, frame rendering, input handling, window management
pub const runtime = @import("runtime/mod.zig");

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
pub const CodeEditor = components.CodeEditor;
pub const ProgressBar = components.ProgressBar;
pub const RadioGroup = components.RadioGroup;
pub const RadioButton = components.RadioButton;
pub const Tab = components.Tab;
pub const TabBar = components.TabBar;
pub const Svg = components.Svg;
pub const Icons = components.Icons;
pub const Lucide = components.Lucide;
pub const Select = components.Select;
pub const Image = components.Image;
pub const AspectRatio = components.AspectRatio;
pub const Tooltip = components.Tooltip;
pub const Modal = components.Modal;
pub const ValidatedTextInput = components.ValidatedTextInput;

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

// Input events (from input module)
pub const InputEvent = input.InputEvent;
pub const KeyEvent = input.KeyEvent;
pub const KeyCode = input.KeyCode;
pub const MouseEvent = input.MouseEvent;
pub const MouseButton = input.MouseButton;
pub const Modifiers = input.Modifiers;

// Scene primitives (from scene module)
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const Hsla = scene.Hsla;
pub const GlyphInstance = scene.GlyphInstance;

// SVG support (from scene module)
pub const svg = scene.svg;

// Image support
pub const ImageAtlas = image.ImageAtlas;
pub const ImageSource = image.ImageSource;
pub const ImageData = image.ImageData;
pub const ObjectFit = image.ObjectFit;

// WASM async image loader (only available on WASM targets)
pub const wasm_image_loader = if (platform.is_wasm)
    @import("platform/web/image_loader.zig")
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

// Render bridge (from scene module)
pub const render_bridge = scene.render_bridge;

// Event system (from input module)
pub const Event = input.Event;
pub const EventPhase = input.EventPhase;
pub const EventResult = input.EventResult;

// Element types
pub const ElementId = core.ElementId;

// Gooey context (from context module)
pub const Gooey = context.Gooey;
pub const WidgetStore = context.WidgetStore;

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

// Data table (virtualized 2D table)
pub const DataTableState = widgets.DataTableState;
pub const DataTableColumn = widgets.DataTableColumn;
pub const SortDirection = widgets.SortDirection;
pub const RowRange = widgets.RowRange;
pub const ColRange = widgets.ColRange;
pub const VisibleRange2D = widgets.VisibleRange2D;

// Tree list (virtualized hierarchical list)
pub const TreeListState = widgets.TreeListState;
pub const TreeNode = widgets.TreeNode;
pub const TreeEntry = widgets.TreeEntry;
pub const TreeLineChar = widgets.TreeLineChar;

// Focus system (from context module)
pub const FocusId = context.FocusId;
pub const FocusHandle = context.FocusHandle;
pub const FocusManager = context.FocusManager;
pub const FocusEvent = context.FocusEvent;

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

// Window management (multi-window support)
pub const WindowId = platform.WindowId;
pub const WindowRegistry = platform.WindowRegistry;
pub const WindowHandle = runtime.WindowHandle;
pub const WindowContext = runtime.WindowContext;

// Multi-window App (for apps with multiple windows sharing resources)
pub const MultiWindowApp = runtime.MultiWindowApp;
pub const AppWindowOptions = runtime.AppWindowOptions;
pub const MAX_WINDOWS = runtime.MAX_WINDOWS;

/// Configuration for runCx
pub const CxConfig = app.CxConfig;

// Custom shaders
pub const CustomShader = core.CustomShader;

// Entity system (from context module)
pub const Entity = context.Entity;
pub const EntityId = context.EntityId;
pub const EntityMap = context.EntityMap;
pub const EntityContext = context.EntityContext;
pub const isView = context.isView;

// Handler system (from context module)
pub const HandlerRef = context.HandlerRef;
pub const typeId = context.typeId;

// Animation system (types from animation module for convenience)
pub const Animation = animation.Animation;
pub const AnimationHandle = animation.AnimationHandle;
pub const Easing = animation.Easing;
pub const Duration = animation.Duration;
pub const lerp = animation.lerp;
pub const lerpInt = animation.lerpInt;
pub const lerpColor = animation.lerpColor;

// Spring physics (from animation module)
pub const spring_mod = @import("animation/spring.zig");
pub const SpringConfig = spring_mod.SpringConfig;
pub const SpringHandle = spring_mod.SpringHandle;

// Stagger animations (from animation module)
pub const stagger_mod = @import("animation/stagger.zig");
pub const StaggerConfig = stagger_mod.StaggerConfig;
pub const StaggerDirection = stagger_mod.StaggerDirection;

// Motion containers (from animation module)
pub const motion_mod = @import("animation/motion.zig");
pub const MotionConfig = motion_mod.MotionConfig;
pub const MotionHandle = motion_mod.MotionHandle;
pub const MotionPhase = motion_mod.MotionPhase;
pub const SpringMotionConfig = motion_mod.SpringMotionConfig;

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
pub const TreeListStyle = ui.TreeListStyle;
pub const DataTableStyle = ui.DataTableStyle;
pub const InputStyle = ui.InputStyle;
pub const TextAreaStyle = ui.TextAreaStyle;
pub const CodeEditorStyle = ui.CodeEditorStyle;

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
// Testing Utilities (only available in test builds)
// =============================================================================

/// Testing utilities and mock implementations
/// Only compiled when running tests to avoid bloating production builds
pub const testing = if (builtin.is_test)
    @import("testing/mod.zig")
else
    struct {};

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
