//! UI Builder
//!
//! The Builder struct is the core of the declarative UI system.
//! It provides methods for creating layouts, rendering primitives,
//! and managing component context.

const std = @import("std");
const canvas_mod = @import("canvas.zig");

// Core imports
const dispatch_mod = @import("../context/dispatch.zig");
const DispatchTree = dispatch_mod.DispatchTree;
const DispatchNodeId = dispatch_mod.DispatchNodeId;
const focus_mod = @import("../context/focus.zig");
const FocusId = focus_mod.FocusId;
const FocusHandle = focus_mod.FocusHandle;
const action_mod = @import("../input/actions.zig");
const actionTypeId = action_mod.actionTypeId;
const handler_mod = @import("../context/handler.zig");
const entity_mod = @import("../context/entity.zig");
const window_mod = @import("../context/window.zig");
const drag_mod = @import("../context/drag.zig");
pub const HandlerRef = handler_mod.HandlerRef;
pub const EntityId = entity_mod.EntityId;
pub const Window = window_mod.Window;

// Accessibility
const a11y = @import("../accessibility/accessibility.zig");

// Layout imports
const layout_types = @import("../layout/types.zig");
const BorderConfig = layout_types.BorderConfig;
const FloatingConfig = layout_types.FloatingConfig;
const layout_mod = @import("../layout/layout.zig");
const LayoutEngine = layout_mod.LayoutEngine;
const LayoutId = layout_mod.LayoutId;
const SourceLoc = layout_mod.SourceLoc;
const Sizing = layout_mod.Sizing;
const SizingAxis = layout_mod.SizingAxis;
const Padding = layout_mod.Padding;
pub const CornerRadius = layout_mod.CornerRadius;
const ChildAlignment = layout_mod.ChildAlignment;
const LayoutDirection = layout_mod.LayoutDirection;
const LayoutConfig = layout_mod.LayoutConfig;
const TextConfig = layout_mod.TextConfig;
const RenderCommand = layout_mod.RenderCommand;
const BoundingBox = layout_mod.BoundingBox;
const MainAxisDistribution = layout_mod.MainAxisDistribution;

// Scene imports
const scene_mod = @import("../scene/mod.zig");
const Scene = scene_mod.Scene;
const Hsla = scene_mod.Hsla;

// Element imports
const styles = @import("styles.zig");
const primitives = @import("primitives.zig");
const theme_mod = @import("theme.zig");
pub const Theme = theme_mod.Theme;

// PR 8.4 — `ScrollContainer` storage moved off
// `WidgetStore.scroll_containers` onto `Window.element_states`. The
// builder is the create-on-touch site for scroll regions, so it
// reaches into the pool directly here. Same import shape as `cx.zig`
// uses for `SelectState` post-PR 8.2.
const scroll_container_mod = @import("../widgets/scroll_container.zig");
const ScrollContainer = scroll_container_mod.ScrollContainer;

// PR 8.4b — `TextInputState` / `TextAreaState` / `CodeEditorState`
// storage moved off the per-type `WidgetStore` StringHashMaps onto
// `Window.element_states`. `Builder.renderInput` / `renderTextArea`
// / `renderCodeEditor` are the create-on-touch sites: each seeds
// the pool entry on first render via `getOrInsert(EngineType,
// layout_id.id, EngineType.init(allocator, default_bounds))` and
// the rest of the framework (frame renderer, input handlers, focus
// register) reads through `get` keyed by `layout_id.id`. Same
// migration shape as `ScrollContainer` (PR 8.4a). The two `Bounds`
// aliases land here so the seeded `init(...)` calls don't reach
// into the engine modules for the type — the builder owns the
// default-bounds policy.
const text_input_state_mod = @import("../widgets/text_input_state.zig");
const TextInputState = text_input_state_mod.TextInputState;
const TextInputBounds = text_input_state_mod.Bounds;
const text_area_state_mod = @import("../widgets/text_area_state.zig");
const TextAreaState = text_area_state_mod.TextAreaState;
const TextAreaBounds = text_area_state_mod.Bounds;
const code_editor_state_mod = @import("../widgets/code_editor_state.zig");
const CodeEditorState = code_editor_state_mod.CodeEditorState;
const CodeEditorBounds = code_editor_state_mod.Bounds;

/// Default bounds used to seed a freshly-allocated text widget pool
/// slot. `Builder.renderInput` / `renderTextArea` / `renderCodeEditor`
/// pass these to `EngineType.init(...)` on the miss path; the actual
/// per-frame bounds are recomputed and written by
/// `runtime/frame.zig::renderTextInputs` / `renderTextAreas` /
/// `renderCodeEditors` once layout has run, so the seed values are
/// only observed by code that touches the widget before its first
/// post-layout render (none today, but the assertions in the
/// engines' `init` paths require sane geometry, e.g.
/// `CodeEditorState.init` asserts `bounds.width > 0`).
const DEFAULT_TEXT_INPUT_BOUNDS: TextInputBounds = .{ .x = 0, .y = 0, .width = 200, .height = 36 };
const DEFAULT_TEXT_AREA_BOUNDS: TextAreaBounds = .{ .x = 0, .y = 0, .width = 300, .height = 150 };
const DEFAULT_CODE_EDITOR_BOUNDS: CodeEditorBounds = .{ .x = 0, .y = 0, .width = 400, .height = 300 };

pub const Color = styles.Color;
pub const ShadowConfig = styles.ShadowConfig;
pub const AttachPoint = styles.AttachPoint;
pub const ObjectFit = styles.ObjectFit;
pub const Floating = styles.Floating;
pub const Box = styles.Box;
pub const TextStyle = styles.TextStyle;
pub const InputStyle = styles.InputStyle;
pub const TextAreaStyle = styles.TextAreaStyle;
pub const CodeEditorStyle = styles.CodeEditorStyle;
pub const StackStyle = styles.StackStyle;
pub const CenterStyle = styles.CenterStyle;
pub const ScrollStyle = styles.ScrollStyle;
pub const UniformListStyle = styles.UniformListStyle;
pub const VirtualListStyle = styles.VirtualListStyle;
pub const DataTableStyle = styles.DataTableStyle;
pub const ButtonStyle = styles.ButtonStyle;

pub const PrimitiveType = primitives.PrimitiveType;
pub const Text = primitives.Text;
pub const Input = primitives.Input;
pub const TextAreaPrimitive = primitives.TextAreaPrimitive;
pub const CodeEditorPrimitive = primitives.CodeEditorPrimitive;
pub const Spacer = primitives.Spacer;
pub const Button = primitives.Button;
pub const ButtonHandler = primitives.ButtonHandler;
pub const Empty = primitives.Empty;
pub const SvgPrimitive = primitives.SvgPrimitive;
pub const ImagePrimitive = primitives.ImagePrimitive;
pub const KeyContextPrimitive = primitives.KeyContextPrimitive;
pub const ActionHandlerPrimitive = primitives.ActionHandlerPrimitive;
pub const ActionHandlerRefPrimitive = primitives.ActionHandlerRefPrimitive;

// Primitive functions
pub const text = primitives.text;
pub const textFmt = primitives.textFmt;
pub const input = primitives.input;
pub const textArea = primitives.textArea;
pub const codeEditor = primitives.codeEditor;
pub const spacer = primitives.spacer;
pub const spacerMin = primitives.spacerMin;
pub const svg = primitives.svg;
pub const svgIcon = primitives.svgIcon;
pub const empty = primitives.empty;
pub const keyContext = primitives.keyContext;
pub const onAction = primitives.onAction;
pub const onActionHandler = primitives.onActionHandler;
pub const when = primitives.when;

// Container element functions (Phase 1: cx/ui separation)
// These return element structs for use with cx.render()
pub const box_element = primitives.box;
pub const hstack_element = primitives.hstack;
pub const vstack_element = primitives.vstack;

// Accessibility config
pub const AccessibleConfig = struct {
    role: a11y.Role,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?[]const u8 = null,
    state: a11y.State = .{},
    live: a11y.Live = .off,
    heading_level: a11y.types.HeadingLevel = .none,
    value_min: ?f32 = null,
    value_max: ?f32 = null,
    value_now: ?f32 = null,
    pos_in_set: ?u16 = null,
    set_size: ?u16 = null,
    /// Optional layout_id for bounds correlation (none = no correlation)
    layout_id: LayoutId = LayoutId.none,

    // =========================================================================
    // Relationships (Phase 3.2) - string IDs that will be resolved to indices
    // =========================================================================

    /// ID of element that labels this one (for aria-labelledby)
    labelled_by_id: ?[]const u8 = null,

    /// ID of element that describes this one (for aria-describedby)
    described_by_id: ?[]const u8 = null,

    /// ID of element this one controls (for aria-controls)
    controls_id: ?[]const u8 = null,
};

// Re-export accessibility types for convenience
pub const A11yRole = a11y.Role;
pub const A11yState = a11y.State;
pub const A11yLive = a11y.Live;

/// Get a unique type ID for context type checking
fn contextTypeId(comptime T: type) usize {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

/// The UI builder context passed to component render() methods
pub const Builder = struct {
    // =========================================================================
    // Limits (per CLAUDE.md: "put a limit on everything")
    // =========================================================================
    pub const MAX_PENDING_INPUTS = 256;
    pub const MAX_PENDING_TEXT_AREAS = 64;
    pub const MAX_PENDING_CODE_EDITORS = 32;
    pub const MAX_PENDING_SCROLLS = 64;
    pub const MAX_PENDING_CANVAS = canvas_mod.MAX_PENDING_CANVAS;
    // PR 11b.3a — the unified text-widget control queue holds one
    // `{ kind, index }` record per text widget, across all three
    // kinds, so its cap is the sum of the three data-plane pools.
    pub const MAX_PENDING_TEXT_WIDGETS =
        MAX_PENDING_INPUTS + MAX_PENDING_TEXT_AREAS + MAX_PENDING_CODE_EDITORS;
    // PR 11b.2a — a single parent cannot hold more auto-id'd children than
    // the layout engine's per-frame element cap, so the sibling index used
    // to derive a parent-scoped auto id is bounded by it. Asserted in
    // `generateId` so a runaway loop fails fast rather than silently
    // wrapping the `u32` counter.
    pub const MAX_AUTO_SIBLINGS = layout_mod.engine.MAX_ELEMENTS_PER_FRAME;

    // PR 11b.2a — fixed seed string mixed into every auto id's hash so the
    // auto-id hash domain can't collapse onto a parent's own layout id (which
    // is `hashString(parent_string, grandparent_id)` — a different seed path).
    const AUTO_ID_SEED = "\x00auto";

    allocator: std.mem.Allocator,
    layout: *LayoutEngine,
    scene: *Scene,
    window: ?*Window = null,
    id_counter: u32 = 0,

    /// Dispatch tree for event routing (built alongside layout)
    dispatch: *DispatchTree,

    // Context storage for component access
    /// Type-erased context pointer (set by runWithState)
    context_ptr: ?*anyopaque = null,
    /// Type ID for runtime type checking
    context_type_id: usize = 0,
    /// Cx pointer for new-style components (set by runCx)
    cx_ptr: ?*anyopaque = null,

    // PR 6 / 7b.4 — theme storage lives on `App.globals` keyed by
    // `*const Theme`. The Builder does not cache a `*const Theme`;
    // `setTheme` writes through the type-keyed registry on the
    // parent `Window`'s borrowed `*App` and `theme()` reads back
    // from the same slot. Rationale: pre-7b.4 the theme slot was
    // per-window — a tab swap in window A would not repaint window
    // B. Lifting the slot to `App.globals` makes the active theme
    // a true app-scoped value (one swap, every window sees the
    // new colors) and matches the GPUI mapping in §10. Collapses
    // two parallel stores (Builder.theme_ptr + the per-window
    // Globals slot the original PR 6 sketch called for) into one
    // app-scoped slot. See `docs/cleanup-implementation-plan.md`
    // PR 6 / 7b.4.

    /// Pending input IDs to be rendered (collected during layout, rendered after)
    pending_inputs: std.ArrayList(PendingInput),
    pending_text_areas: std.ArrayList(PendingTextArea),
    pending_code_editors: std.ArrayList(PendingCodeEditor),

    /// PR 11b.3a — unified control-plane queue for the post-layout
    /// text-widget render pass. The three pools above are the data
    /// plane (right-sized, typed); this queue records one tiny
    /// `{ kind, index }` per widget in tree order so the render pass
    /// can replay all three kinds interleaved in the order they were
    /// built. Tree-order replay is strictly more correct than the
    /// old grouped (inputs, then areas, then editors) order when
    /// widgets of different kinds overlap. A `{ kind, index }` record
    /// (rather than a tagged union over the style structs) keeps each
    /// slot at 8 bytes instead of sizing every slot to the largest
    /// variant (`CodeEditorStyle`) — control plane / data plane split,
    /// CLAUDE.md §8.
    pending_text_widgets: std.ArrayList(PendingTextWidget),
    pending_scrolls: std.ArrayListUnmanaged(PendingScroll),
    pending_canvas: std.ArrayListUnmanaged(canvas_mod.PendingCanvas),

    /// Hashmap for O(1) scroll lookup by layout_id (avoids O(n) scan per scissor_end)
    pending_scrolls_by_layout_id: std.AutoHashMapUnmanaged(u32, usize),

    /// Currently dragged scroll container ID (avoids O(n) scan per
    /// mouse drag event). PR 8.4 — storage moved off
    /// `WidgetStore.scroll_containers` (string-keyed) onto
    /// `Window.element_states` (layout-id-hash-keyed), so the cached
    /// drag id is now the u32 hash. Avoids re-hashing the string at
    /// every drag event and — critically — sidesteps the lifetime
    /// hazard of holding a borrowed `[]const u8` across the
    /// frame-render boundary that used to free the duped key.
    active_scroll_drag_id: ?u32 = null,

    /// PR 11b.3a — the kind discriminant for the unified text-widget
    /// control queue. Mirrors the three typed data-plane pools; the
    /// render pass switches on it at comptime (no runtime trait
    /// objects) to pick the matching pool and per-kind render path.
    pub const TextWidgetKind = enum { input, text_area, code_editor };

    /// PR 11b.3a — one control-plane record: which pool, and which
    /// slot within it. 8 bytes; the heavy per-widget state stays in
    /// the typed pools.
    pub const PendingTextWidget = struct {
        kind: TextWidgetKind,
        index: u32,
    };

    pub const PendingInput = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: InputStyle,
        inner_width: f32,
        inner_height: f32,
        on_blur_handler: ?HandlerRef = null,
    };

    pub const PendingTextArea = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: TextAreaStyle,
        inner_width: f32,
        inner_height: f32,
        on_blur_handler: ?HandlerRef = null,
    };

    pub const PendingCodeEditor = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: CodeEditorStyle,
        inner_width: f32,
        inner_height: f32,
        on_blur_handler: ?HandlerRef = null,
    };

    pub const PendingScroll = struct {
        id: []const u8,
        layout_id: LayoutId,
        style: ScrollStyle,
        content_layout_id: LayoutId,
    };

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        layout_engine: *LayoutEngine,
        scene_ptr: *Scene,
        dispatch_tree: *DispatchTree,
    ) Self {
        return .{
            .allocator = allocator,
            .layout = layout_engine,
            .scene = scene_ptr,
            .dispatch = dispatch_tree,
            .pending_inputs = .empty,
            .pending_scrolls = .empty,
            .pending_text_areas = .empty,
            .pending_code_editors = .empty,
            .pending_text_widgets = .empty,
            .pending_canvas = .empty,
            .pending_scrolls_by_layout_id = .{},
            .active_scroll_drag_id = null,
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_inputs.deinit(self.allocator);
        self.pending_text_areas.deinit(self.allocator);
        self.pending_code_editors.deinit(self.allocator);
        self.pending_text_widgets.deinit(self.allocator);
        self.pending_scrolls.deinit(self.allocator);
        self.pending_canvas.deinit(self.allocator);
        self.pending_scrolls_by_layout_id.deinit(self.allocator);
    }

    // =========================================================================
    // Text-widget control queue (PR 11b.3a)
    // =========================================================================

    /// Record a `{ kind, index }` control-plane entry pointing at the
    /// slot a `renderInput` / `renderTextArea` / `renderCodeEditor`
    /// just appended to its typed data-plane pool. Callers must invoke
    /// this only after confirming the data-plane append landed, so the
    /// recorded index always resolves to a live slot during the
    /// post-layout render pass.
    fn enqueuePendingTextWidget(self: *Self, kind: TextWidgetKind, index: usize) void {
        std.debug.assert(index <= std.math.maxInt(u32));
        std.debug.assert(self.pending_text_widgets.items.len < MAX_PENDING_TEXT_WIDGETS);
        self.pending_text_widgets.append(self.allocator, .{
            .kind = kind,
            .index = @intCast(index),
        }) catch {};
    }

    // =========================================================================
    // Canvas Registration
    // =========================================================================

    /// Register a pending canvas for deferred rendering after layout.
    pub fn registerPendingCanvas(self: *Self, pending: canvas_mod.PendingCanvas) void {
        std.debug.assert(self.pending_canvas.items.len < MAX_PENDING_CANVAS);
        self.pending_canvas.append(self.allocator, pending) catch {};
    }

    /// Get pending canvas elements for rendering
    pub fn getPendingCanvas(self: *const Self) []const canvas_mod.PendingCanvas {
        return self.pending_canvas.items;
    }

    // =========================================================================
    // Context Access (for components to retrieve typed context)
    // =========================================================================

    /// Set the context for this builder.
    /// Called by runWithState before rendering.
    pub fn setContext(self: *Self, comptime ContextType: type, ctx: *ContextType) void {
        self.context_ptr = @ptrCast(ctx);
        self.context_type_id = contextTypeId(ContextType);
    }

    /// Clear the context (called after frame if needed)
    pub fn clearContext(self: *Self) void {
        self.context_ptr = null;
        self.context_type_id = 0;
    }

    // =========================================================================
    // Theme Access
    // =========================================================================

    /// Set the theme for this builder and all child components.
    /// Called at the start of render to establish theme context.
    ///
    /// PR 6 / 7b.4: writes through to `app.globals` keyed by
    /// `Theme`. `replaceBorrowedConst` registers a fresh slot on
    /// the first call and rebinds the pointer on subsequent calls
    /// without growing the table — same behaviour the old
    /// `theme_ptr` assignment had, just routed through the
    /// type-keyed store on the parent `App`. Pre-7b.4 the slot
    /// lived on `Window.globals`, which made cross-window theme
    /// sharing structurally impossible; lifting to `App.globals`
    /// is what makes a single `cx.setTheme(&Theme.dark)` repaint
    /// every window in a multi-window app.
    ///
    /// Asserts `self.window` is wired. Every code path that builds
    /// a frame (`Cx.setTheme`, the runtime drivers) goes through
    /// a `Window`-attached builder; a null parent here is a
    /// framework bug, not a runtime fallback.
    pub fn setTheme(self: *Self, t: *const Theme) void {
        const g = self.window orelse {
            std.debug.panic(
                "Builder.setTheme: builder has no parent Window; cannot route theme through globals",
                .{},
            );
        };
        g.app.globals.replaceBorrowedConst(Theme, t);
    }

    /// Get the current theme, falling back to light theme if none set.
    /// Components use this to resolve null color fields.
    ///
    /// PR 6 / 7b.4: reads from `app.globals`. The `*const Theme`
    /// slot may be empty (no `setTheme` yet this frame, or the
    /// builder was stood up bare for a unit test that bypassed
    /// the `App` wiring) — fall back to `&Theme.light` in that
    /// case so the component path stays branch-free. Pre-7b.4
    /// the slot was read from `window.globals`; the lift to
    /// `app.globals` is transparent to call sites because every
    /// `Window` that has a parent `App` wired (every framework
    /// init path) reaches the same slot.
    pub fn theme(self: *Self) *const Theme {
        const g = self.window orelse return &Theme.light;
        return g.app.globals.getConst(Theme) orelse &Theme.light;
    }

    /// Get the typed context from within a component's render method.
    ///
    /// Returns null if no context is set or if the type doesn't match.
    ///
    /// ## Example
    ///
    /// ```zig
    /// const CounterRow = struct {
    ///     pub fn render(_: @This(), b: *ui.Builder) void {
    ///         const cx = b.getContext(gooey.Context(AppState)) orelse return;
    ///         const s = cx.state();
    ///
    ///         b.hstack(.{ .gap = 12 }, .{
    ///             ui.buttonHandler("-", cx.handler(AppState.decrement)),
    ///             ui.textFmt("Count: {}", .{s.count}, .{}),
    ///             ui.buttonHandler("+", cx.handler(AppState.increment)),
    ///         });
    ///     }
    /// };
    /// ```
    pub fn getContext(self: *Self, comptime ContextType: type) ?*ContextType {
        if (self.context_ptr) |ptr| {
            if (self.context_type_id == contextTypeId(ContextType)) {
                return @ptrCast(@alignCast(ptr));
            }
        }
        return null;
    }

    /// Get an EntityContext for an entity from within a component's render method.
    ///
    /// This is a convenience that combines `b.window` access with entity context creation,
    /// eliminating the need for global Window references in entity-based components.
    ///
    /// ## Example
    ///
    /// ```zig
    /// const CounterButtons = struct {
    ///     counter: gooey.Entity(Counter),
    ///
    ///     pub fn render(self: @This(), b: *ui.Builder) void {
    ///         var cx = b.entityContext(Counter, self.counter) orelse return;
    ///
    ///         b.hstack(.{ .gap = 8 }, .{
    ///             ui.buttonHandler("-", cx.handler(Counter.decrement)),
    ///             ui.buttonHandler("+", cx.handler(Counter.increment)),
    ///         });
    ///     }
    /// };
    /// ```
    pub fn entityContext(
        self: *Self,
        comptime T: type,
        entity: entity_mod.Entity(T),
    ) ?entity_mod.EntityContext(T) {
        const g = self.window orelse return null;
        return entity.context(g);
    }

    /// Get the Window instance from within a component.
    ///
    /// Useful for reading entity data or other Window operations.
    /// Returns null if Builder wasn't initialized with a Window reference.
    pub fn getGooey(self: *Self) ?*Window {
        return self.window;
    }

    /// Read an entity's data directly from Builder.
    /// Convenience wrapper around gooey.readEntity().
    pub fn readEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*const T {
        const g = self.window orelse return null;
        return g.readEntity(T, entity);
    }

    /// Write to an entity's data directly from Builder.
    /// Convenience wrapper around gooey.writeEntity().
    pub fn writeEntity(self: *Self, comptime T: type, entity: entity_mod.Entity(T)) ?*T {
        const g = self.window orelse return null;
        return g.writeEntity(T, entity);
    }

    // =========================================================================
    // Accessibility (Phase 1)
    // =========================================================================

    /// Begin an accessible element. Call before the visual element.
    /// Returns true if a11y is active and element was pushed.
    /// Must be paired with accessibleEnd() when returns true.
    ///
    /// Focus state is automatically injected from the FocusManager based on
    /// the layout_id - components don't need to manually track focus.
    ///
    /// ## Example
    /// ```zig
    /// if (b.accessible(.{ .role = .button, .name = "Submit" })) {
    ///     defer b.accessibleEnd();
    /// }
    /// // ... render visual element ...
    /// ```
    pub fn accessible(self: *Self, config: AccessibleConfig) bool {
        const g = self.window orelse return false;
        if (!g.a11y.isEnabled()) return false;

        // Phase 3: Auto-inject focus state from FocusManager
        // This centralizes focus tracking - components don't need to know about it
        var state = config.state;
        if (config.layout_id.id != 0) {
            // Check if this element is focused via FocusManager
            const focus_id = FocusId.fromLayoutId(config.layout_id);
            if (g.focus.isFocused(focus_id)) {
                state.focused = true;
            }
        }

        // Resolve string-based relationship IDs to element indices
        // Note: Target elements must be rendered earlier in the same frame
        const a11y_tree = g.a11y.getTree();
        const labelled_by: ?u16 = if (config.labelled_by_id) |id|
            a11y_tree.findElementByStringId(id)
        else
            null;

        const described_by: ?u16 = if (config.described_by_id) |id|
            a11y_tree.findElementByStringId(id)
        else
            null;

        const controls: ?u16 = if (config.controls_id) |id|
            a11y_tree.findElementByStringId(id)
        else
            null;

        _ = a11y_tree.pushElement(.{
            .layout_id = config.layout_id,
            .role = config.role,
            .name = config.name,
            .description = config.description,
            .value = config.value,
            .state = state,
            .live = config.live,
            .heading_level = config.heading_level,
            .value_min = config.value_min,
            .value_max = config.value_max,
            .value_now = config.value_now,
            .pos_in_set = config.pos_in_set,
            .set_size = config.set_size,
            // Relationships
            .labelled_by = labelled_by,
            .described_by = described_by,
            .controls = controls,
        });

        return true;
    }

    /// End current accessible element.
    /// Must be called after accessible() returns true.
    pub fn accessibleEnd(self: *Self) void {
        const g = self.window orelse return;
        if (g.a11y.isEnabled()) {
            g.a11y.getTree().popElement();
        }
    }

    /// Announce a message to screen readers.
    /// Use .polite for non-urgent updates, .assertive for critical alerts.
    ///
    /// ## Example
    /// ```zig
    /// b.announce("Item deleted", .polite);
    /// b.announce("Error: connection lost", .assertive);
    /// ```
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        const g = self.window orelse return;
        g.a11y.announce(message, priority);
    }

    /// Check if accessibility is currently enabled
    pub fn isA11yEnabled(self: *Self) bool {
        const g = self.window orelse return false;
        return g.a11y.isEnabled();
    }

    // =========================================================================
    // Container Methods
    // =========================================================================

    /// Generic box container with children
    pub fn box(self: *Self, props: Box, children: anytype) void {
        self.boxWithIdTracked(null, props, children, SourceLoc.none);
    }

    /// Childless box — a visual-only rectangle (divider, spacer, colored block).
    /// Equivalent to `box(props, .{})` without the empty children tuple.
    pub fn rect(self: *Self, props: Box) void {
        self.boxWithIdTracked(null, props, .{}, SourceLoc.none);
    }

    /// Box with source location tracking (Phase 5)
    /// Call as: b.boxTracked(props, children, @src())
    pub fn boxTracked(self: *Self, props: Box, children: anytype, src: std.builtin.SourceLocation) void {
        self.boxWithIdTracked(null, props, children, SourceLoc.from(src));
    }

    /// Box with explicit ID
    pub fn boxWithId(self: *Self, id: ?[]const u8, props: Box, children: anytype) void {
        self.boxWithIdTracked(id, props, children, SourceLoc.none);
    }

    /// Box with pre-generated LayoutId (for canvas and other deferred rendering)
    pub fn boxWithLayoutId(self: *Self, layout_id: LayoutId, props: Box, children: anytype) void {
        self.boxWithLayoutIdImpl(layout_id, props, children, SourceLoc.none, false);
    }

    /// Box with pre-generated LayoutId marked as a canvas element for proper z-ordering
    pub fn boxWithLayoutIdCanvas(self: *Self, layout_id: LayoutId, props: Box, children: anytype) void {
        self.boxWithLayoutIdImpl(layout_id, props, children, SourceLoc.none, true);
    }

    /// Box with explicit ID and source location tracking (Phase 5)
    /// Call as: b.boxWithIdTracked("my-id", props, children, @src())
    pub fn boxWithIdTracked(self: *Self, id: ?[]const u8, props: Box, children: anytype, source_loc: SourceLoc) void {
        const layout_id = if (id) |i| LayoutId.fromString(i) else self.generateId();
        self.boxWithLayoutIdImpl(layout_id, props, children, source_loc, false);
    }

    /// Internal: Box implementation with pre-resolved LayoutId
    fn boxWithLayoutIdImpl(self: *Self, layout_id: LayoutId, props: Box, children: anytype, source_loc: SourceLoc, is_canvas: bool) void {

        // Push dispatch node at element open
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Resolve hover styles - check if this element is currently hovered
        const is_hovered = if (self.window) |g|
            g.isHovered(layout_id.id)
        else
            false;

        // Check if this is a valid drag-over target
        const is_drag_over = if (self.window) |g| blk: {
            if (g.active_drag) |drag| {
                if (props.drop_target) |drop| {
                    // Type must match AND cursor must be over this element
                    if (drag.type_id == drop.type_id and g.isDragOverTarget(layout_id.id)) {
                        break :blk true;
                    }
                }
            }
            break :blk false;
        } else false;

        // Resolve background with drag-over priority
        const resolved_background = if (is_drag_over and props.drag_over_background != null)
            props.drag_over_background.?
        else if (is_hovered and props.hover_background != null)
            props.hover_background.?
        else
            props.background;

        const resolved_border_color = if (is_drag_over and props.drag_over_border_color != null)
            props.drag_over_border_color.?
        else if (is_hovered and props.hover_border_color != null)
            props.hover_border_color.?
        else
            props.border_color;

        var sizing = Sizing.fitContent();

        // Width sizing - grow takes precedence when combined with min/max
        const grow_w = props.grow or props.grow_width;
        if (grow_w) {
            const min_w = props.min_width orelse 0;
            const max_w = props.max_width orelse std.math.floatMax(f32);
            sizing.width = SizingAxis.growMinMax(min_w, max_w);
        } else if (props.width) |w| {
            if (props.min_width != null or props.max_width != null) {
                const min_w = props.min_width orelse 0;
                const max_w = props.max_width orelse w;
                sizing.width = SizingAxis.fitMinMax(min_w, @min(w, max_w));
            } else {
                sizing.width = SizingAxis.fixed(w);
            }
        } else if (props.min_width != null or props.max_width != null) {
            const min_w = props.min_width orelse 0;
            const max_w = props.max_width orelse std.math.floatMax(f32);
            sizing.width = SizingAxis.fitMinMax(min_w, max_w);
        } else if (props.width_percent) |p| {
            sizing.width = SizingAxis.percent(p);
        } else if (props.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        }

        // Height sizing - grow takes precedence when combined with min/max
        const grow_h = props.grow or props.grow_height;
        if (grow_h) {
            const min_h = props.min_height orelse 0;
            const max_h = props.max_height orelse std.math.floatMax(f32);
            sizing.height = SizingAxis.growMinMax(min_h, max_h);
        } else if (props.height) |h| {
            if (props.min_height != null or props.max_height != null) {
                const min_h = props.min_height orelse 0;
                const max_h = props.max_height orelse h;
                sizing.height = SizingAxis.fitMinMax(min_h, @min(h, max_h));
            } else {
                sizing.height = SizingAxis.fixed(h);
            }
        } else if (props.min_height != null or props.max_height != null) {
            const min_h = props.min_height orelse 0;
            const max_h = props.max_height orelse std.math.floatMax(f32);
            sizing.height = SizingAxis.fitMinMax(min_h, max_h);
        } else if (props.height_percent) |p| {
            sizing.height = SizingAxis.percent(p);
        } else if (props.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        }

        const direction: LayoutDirection = switch (props.direction) {
            .row => .left_to_right,
            .column => .top_to_bottom,
        };

        // Alignment mapping depends on direction:
        // - row: main=X, cross=Y
        // - column: main=Y, cross=X
        const child_alignment = if (props.direction == .row) ChildAlignment{
            .x = switch (props.alignment.main) {
                .start => .left,
                .center => .center,
                .end => .right,
                .space_between, .space_around, .space_evenly => .left,
            },
            .y = switch (props.alignment.cross) {
                .start => .top,
                .center => .center,
                .end => .bottom,
                .stretch => .top,
            },
        } else ChildAlignment{
            .x = switch (props.alignment.cross) {
                .start => .left,
                .center => .center,
                .end => .right,
                .stretch => .left,
            },
            .y = switch (props.alignment.main) {
                .start => .top,
                .center => .center,
                .end => .bottom,
                .space_between, .space_around, .space_evenly => .top,
            },
        };

        // Map main-axis distribution (for space-between, space-around, etc.)
        const main_distribution: MainAxisDistribution = switch (props.alignment.main) {
            .start => .start,
            .center => .center,
            .end => .end,
            .space_between => .space_between,
            .space_around => .space_around,
            .space_evenly => .space_evenly,
        };

        // Build border config if we have a border
        const border_config: ?BorderConfig = if (props.hasBorder())
            .{ .color = resolved_border_color, .width = props.toBorderWidth() }
        else
            null;

        // Convert floating config if present
        const floating_config: ?FloatingConfig = if (props.floating) |f|
            f.toFloatingConfig()
        else
            null;

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = sizing,
                .padding = props.toPadding(),
                .child_gap = @intFromFloat(props.gap),
                .child_alignment = child_alignment,
                .layout_direction = direction,
                .main_axis_distribution = main_distribution,
            },
            .background_color = resolved_background,
            .corner_radius = CornerRadius.all(props.corner_radius),
            .border = border_config,
            .shadow = props.shadow,
            .floating = floating_config,
            .opacity = props.opacity,
            .source_location = source_loc,
            .is_canvas = is_canvas,
        }) catch return;

        // Mark floating elements for hit testing optimization
        if (floating_config != null) {
            self.dispatch.markFloating();
        }

        self.processChildren(children);

        self.layout.closeElement();

        // Register click handlers before popping dispatch node
        if (props.on_click) |callback| {
            self.dispatch.onClick(callback);
        }
        if (props.on_click_handler) |handler| {
            self.dispatch.onClickHandler(handler);
        }

        // Register click-outside handlers (for dropdowns, modals, etc.)
        if (props.on_click_outside) |callback| {
            self.dispatch.onClickOutside(callback);
        }
        if (props.on_click_outside_handler) |handler| {
            self.dispatch.onClickOutsideHandler(handler);
        }

        // Register drag source
        if (props.draggable) |drag| {
            const node_id = self.dispatch.currentNode();
            if (self.dispatch.getNode(node_id)) |node| {
                node.drag_source = .{
                    .value_ptr = drag.value_ptr,
                    .type_id = drag.type_id,
                };
            }
        }

        // Register drop target
        if (props.drop_target) |drop| {
            const node_id = self.dispatch.currentNode();
            if (self.dispatch.getNode(node_id)) |node| {
                node.drop_target = .{
                    .type_id = drop.type_id,
                    .handler = drop.handler,
                };
            }
        }

        // Set pointer events mode
        if (props.pointer_events == .none) {
            const node_id = self.dispatch.currentNode();
            if (self.dispatch.getNode(node_id)) |node| {
                node.pointer_events_none = true;
            }
        }

        // Pop dispatch node at element close
        self.dispatch.popNode();
    }

    /// Vertical stack (column)
    pub fn vstack(self: *Self, style: StackStyle, children: anytype) void {
        self.vstackImpl(style, children, SourceLoc.none);
    }

    /// Vertical stack with source location tracking (Phase 5)
    /// Call as: b.vstackTracked(style, children, @src())
    pub fn vstackTracked(self: *Self, style: StackStyle, children: anytype, src: std.builtin.SourceLocation) void {
        self.vstackImpl(style, children, SourceLoc.from(src));
    }

    fn vstackImpl(self: *Self, style: StackStyle, children: anytype, loc: SourceLoc) void {
        self.boxWithIdTracked(null, .{
            .direction = .column,
            .gap = style.gap,
            .padding = .{ .all = style.padding },
            .alignment = .{
                .cross = switch (style.alignment) {
                    .start => .start,
                    .center => .center,
                    .end => .end,
                    .stretch => .stretch,
                },
            },
        }, children, loc);
    }

    /// Horizontal stack (row)
    pub fn hstack(self: *Self, style: StackStyle, children: anytype) void {
        self.hstackImpl(style, children, SourceLoc.none);
    }

    /// Horizontal stack with source location tracking (Phase 5)
    /// Call as: b.hstackTracked(style, children, @src())
    pub fn hstackTracked(self: *Self, style: StackStyle, children: anytype, src: std.builtin.SourceLocation) void {
        self.hstackImpl(style, children, SourceLoc.from(src));
    }

    fn hstackImpl(self: *Self, style: StackStyle, children: anytype, loc: SourceLoc) void {
        self.boxWithIdTracked(null, .{
            .direction = .row,
            .gap = style.gap,
            .padding = .{ .all = style.padding },
            .alignment = .{
                .cross = switch (style.alignment) {
                    .start => .start,
                    .center => .center,
                    .end => .end,
                    .stretch => .stretch,
                },
            },
        }, children, loc);
    }

    /// Center children in available space
    pub fn center(self: *Self, style: CenterStyle, children: anytype) void {
        self.box(.{
            .grow = true,
            .padding = .{ .all = style.padding },
            .alignment = .{ .main = .center, .cross = .center },
        }, children);
    }

    // =========================================================================
    // Component Integration
    // =========================================================================
    //
    // `Builder.with` was removed in PR 11b.1. It passed `*Builder` to a
    // component's `render`, but components now author against `*Cx`, so
    // the only correct entry point is `Cx.with` (which routes through the
    // `*Cx`-aware dispatch). All former `b.with(...)` call sites migrated
    // to `cx.with(...)`.

    // =========================================================================
    // Conditionals
    // =========================================================================

    /// Render children only if condition is true
    pub fn when(self: *Self, condition: bool, children: anytype) void {
        if (condition) {
            self.processChildren(children);
        }
    }

    /// Render with value if optional is non-null
    pub fn maybe(self: *Self, optional: anytype, comptime render_fn: anytype) void {
        if (optional) |value| {
            const result = render_fn(value);
            self.processChild(result);
        }
    }

    // =========================================================================
    // Iteration
    // =========================================================================

    /// Render for each item in a slice
    pub fn each(self: *Self, items: anytype, comptime render_fn: anytype) void {
        for (items, 0..) |item, index| {
            const result = render_fn(item, index);
            self.processChild(result);
        }
    }

    /// Create a scrollable container
    /// Usage: b.scroll("my_scroll", .{ .height = 200 }, .{ ...children... });
    pub fn scroll(self: *Self, id: []const u8, style: ScrollStyle, children: anytype) void {
        const layout_id = LayoutId.fromString(id);

        // Push dispatch node for hit testing (must match layout structure)
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Get scroll offset from retained widget. PR 8.4 — storage
        // lifted off `WidgetStore.scroll_containers` onto
        // `Window.element_states`; the layout-id hash is the pool
        // key. The miss path here also seeds the pool entry so that
        // the subsequent `registerPendingScrollRegions` walk can
        // assume the slot exists, mirroring the pre-PR-8.4
        // create-on-touch shape `widgets.scrollContainer(id)` had.
        var scroll_offset_x: f32 = 0;
        var scroll_offset_y: f32 = 0;
        if (self.window) |g| {
            const sc_or_null = g.element_states.getOrInsert(
                ScrollContainer,
                @as(u64, layout_id.id),
                ScrollContainer.init(g.allocator),
            ) catch null;
            if (sc_or_null) |sc| {
                scroll_offset_x = sc.state.offset_x;
                scroll_offset_y = sc.state.offset_y;
            }
        }

        // Convert padding
        const padding: Padding = switch (style.padding) {
            .all => |v| Padding.all(@intFromFloat(v)),
            .symmetric => |s| Padding.symmetric(@intFromFloat(s.x), @intFromFloat(s.y)),
            .each => |e| .{
                .top = @intFromFloat(e.top),
                .right = @intFromFloat(e.right),
                .bottom = @intFromFloat(e.bottom),
                .left = @intFromFloat(e.left),
            },
        };

        // Compute viewport sizing (same pattern as boxWithIdTracked)
        var sizing = Sizing.fitContent();

        // Width sizing
        const grow_w = style.grow or style.grow_width;
        if (grow_w) {
            sizing.width = SizingAxis.grow();
        } else if (style.width) |w| {
            sizing.width = SizingAxis.fixed(w);
        } else if (style.fill_width) {
            sizing.width = SizingAxis.percent(1.0);
        } else {
            // Default fallback for scroll containers
            sizing.width = SizingAxis.fixed(300);
        }

        // Height sizing
        const grow_h = style.grow or style.grow_height;
        if (grow_h) {
            sizing.height = SizingAxis.grow();
        } else if (style.height) |h| {
            sizing.height = SizingAxis.fixed(h);
        } else if (style.fill_height) {
            sizing.height = SizingAxis.percent(1.0);
        } else {
            // Default fallback for scroll containers
            sizing.height = SizingAxis.fixed(200);
        }

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = sizing,
                .padding = padding,
            },
            .background_color = style.background,
            .corner_radius = if (style.corner_radius > 0) CornerRadius.all(style.corner_radius) else .{},
            .scroll = .{
                .vertical = style.vertical,
                .horizontal = style.horizontal,
                .scroll_offset = .{ .x = scroll_offset_x, .y = scroll_offset_y },
            },
        }) catch return;

        // Inner content container (can be taller than viewport)
        const content_id = self.generateId();
        // Content sizing: use fit() for scrollable directions (allows overflow),
        // grow() for non-scrollable directions (fills viewport)
        const content_width_sizing = if (style.content_width) |w|
            SizingAxis.fixed(w)
        else if (style.horizontal)
            SizingAxis.fit() // fit to children, allows horizontal overflow
        else
            SizingAxis.grow(); // fill viewport width

        const content_height_sizing = if (style.content_height) |h|
            SizingAxis.fixed(h)
        else if (style.vertical)
            SizingAxis.fit() // fit to children, allows vertical overflow
        else
            SizingAxis.grow(); // fill viewport height

        self.layout.openElement(.{
            .id = content_id,
            .layout = .{
                .sizing = .{
                    .width = content_width_sizing,
                    .height = content_height_sizing,
                },
                .layout_direction = .top_to_bottom,
                .child_gap = style.gap,
            },
        }) catch return;

        // Process children
        self.processChildren(children);

        // Close content container
        self.layout.closeElement();

        // Close viewport
        self.layout.closeElement();

        // Store for later processing
        const index = self.pending_scrolls.items.len;
        self.pending_scrolls.append(self.allocator, .{
            .id = id,
            .layout_id = layout_id,
            .style = style,
            .content_layout_id = content_id,
        }) catch return;

        // Add to hashmap for O(1) lookup by layout_id
        self.pending_scrolls_by_layout_id.put(self.allocator, layout_id.id, index) catch {};

        // Pop dispatch node (matches pushNode at function start)
        self.dispatch.popNode();
    }

    /// Find a pending scroll by its layout ID (for rendering scrollbars inline with commands)
    /// O(1) lookup for pending scroll by layout_id (uses hashmap)
    pub fn findPendingScrollByLayoutId(self: *const Self, layout_id_value: u32) ?*const PendingScroll {
        if (self.pending_scrolls_by_layout_id.get(layout_id_value)) |index| {
            if (index < self.pending_scrolls.items.len) {
                return &self.pending_scrolls.items[index];
            }
        }
        return null;
    }

    /// Track which scroll container is being dragged (for O(1) drag
    /// event handling). The `id` is the `LayoutId.id` u32 hash that
    /// keys the `Window.element_states` slot post-PR 8.4.
    pub fn setActiveScrollDrag(self: *Self, id: ?u32) void {
        self.active_scroll_drag_id = id;
    }

    /// Get the currently dragged scroll container ID (u32 layout-id
    /// hash that keys `Window.element_states`).
    pub fn getActiveScrollDrag(self: *const Self) ?u32 {
        return self.active_scroll_drag_id;
    }

    // =========================================================================
    // List rendering helpers (moved per PR 4)
    // =========================================================================
    //
    // The Uniform List, Virtual List, and Data Table builder helpers have
    // been moved into their respective widget files
    // (`src/widgets/uniform_list.zig`, `src/widgets/virtual_list.zig`,
    // `src/widgets/data_table.zig`) per PR 4 of
    // `docs/cleanup-implementation-plan.md` to break the `ui → widgets`
    // backward edge. They take `*Builder` as their first argument and
    // append to `b.pending_scrolls` directly. See those files for the
    // moved helpers (`computeLayout`, `openElements`, `renderSpacer`,
    // `registerScroll`, `syncScroll`, plus `renderHeaderCx` /
    // `renderRowCx` for data tables).

    /// Register scroll container regions and update state
    pub fn registerPendingScrollRegions(self: *Self) void {
        for (self.pending_scrolls.items) |pending| {
            const viewport_bounds = self.layout.getBoundingBox(pending.layout_id.id);
            const viewport_content = self.layout.getContentBox(pending.layout_id.id);
            const content_bounds = self.layout.getBoundingBox(pending.content_layout_id.id);

            if (viewport_bounds != null and viewport_content != null and content_bounds != null) {
                const vp = viewport_bounds.?;
                const vp_content = viewport_content.?;
                const ct = content_bounds.?;

                if (self.window) |g| {
                    // PR 8.4 — the slot was seeded by `Builder.scroll`
                    // earlier in the frame, so a read-only `get` is
                    // sufficient here. If the slot is missing (only
                    // possible under capacity exhaustion at scroll-time),
                    // skip the bounds update for this frame; the
                    // `pending_scrolls` queue will retry next render.
                    if (g.element_states.get(ScrollContainer, @as(u64, pending.layout_id.id))) |sc| {
                        // Update bounds (full bounding box for hit testing)
                        sc.bounds = .{
                            .x = vp.x,
                            .y = vp.y,
                            .width = vp.width,
                            .height = vp.height,
                        };

                        // Update viewport size using content box (inside padding)
                        // This ensures scroll range accounts for padding correctly
                        sc.setViewport(vp_content.width, vp_content.height);
                        sc.setContentSize(ct.width, ct.height);

                        // Apply scroll directions
                        sc.style.horizontal = pending.style.horizontal;
                        sc.style.vertical = pending.style.vertical;

                        // Apply theme colors if provided
                        if (pending.style.track_color) |c| sc.style.track_color = c;
                        if (pending.style.thumb_color) |c| sc.style.thumb_color = c;
                        sc.style.scrollbar_size = pending.style.scrollbar_size;
                    }
                }
            }
        }
    }

    // =========================================================================
    // Internal: Child Processing
    // =========================================================================

    pub fn processChildren(self: *Self, children: anytype) void {
        const T = @TypeOf(children);
        const type_info = @typeInfo(T);

        if (type_info == .@"struct" and type_info.@"struct".is_tuple) {
            inline for (children) |child| {
                self.processChild(child);
            }
        } else if (type_info == .array) {
            // Handle fixed-size arrays of components (e.g., [N]StaggeredRow from stagger)
            for (children) |child| {
                self.processChild(child);
            }
        } else {
            self.processChild(children);
        }
    }

    fn processChild(self: *Self, child: anytype) void {
        const T = @TypeOf(child);
        const type_info = @typeInfo(T);

        // Handle null (from conditionals)
        if (T == @TypeOf(null)) {
            return;
        }

        // Handle optional types
        if (type_info == .optional) {
            if (child) |val| {
                self.processChild(val);
            }
            return;
        }

        if (type_info != .@"struct") {
            return;
        }

        // Check for primitives
        if (@hasDecl(T, "primitive_type")) {
            const prim_type: PrimitiveType = T.primitive_type;
            switch (prim_type) {
                .text => self.renderText(child),
                .input => self.renderInput(child),
                .text_area => self.renderTextArea(child),
                .code_editor => self.renderCodeEditor(child),
                .spacer => self.renderSpacer(child),
                .button => self.renderButton(child),
                .key_context => self.renderKeyContext(child),
                .action_handler => self.renderActionHandler(child),
                .button_handler => self.renderButtonHandler(child),
                .action_handler_ref => self.renderActionHandlerRef(child),
                .svg => self.renderSvg(child),
                .image => self.renderImage(child),
                .empty => {}, // Do nothing
                // Container elements (Phase 1: cx/ui separation)
                // These have render() methods, so they'll be handled by the component check below
                // But we handle them explicitly here for clarity and to avoid the component path
                .box_element, .hstack, .vstack, .scroll => child.render(self),
            }
            return;
        }

        // Check for components (structs with a `render` method). Since
        // PR 11b.1 there is exactly one component signature:
        // `render(self, *Cx)`. The old `render(self, *Builder)` branch is
        // gone, so authors have a single way to write a component.
        if (@hasDecl(T, "render")) {
            const render_fn = @field(T, "render");
            const fn_info = @typeInfo(@TypeOf(render_fn)).@"fn";

            if (fn_info.params.len >= 2) {
                const CxType = fn_info.params[1].type orelse
                    @compileError("component `render` must take a typed `*Cx` second parameter");

                // The builder always has a bound `cx_ptr` while rendering
                // — it is wired at construction in `app.zig` and
                // `runtime/window_context.zig`. A null here means a
                // component is being processed outside a real frame,
                // which is a programming error, not a recoverable state
                // (CLAUDE.md §11, §17: assert the invariant, never
                // silently drop the element).
                const cx_raw = self.cx_ptr orelse unreachable;
                const cx: CxType = @ptrCast(@alignCast(cx_raw));
                child.render(cx);
            }
            return;
        }

        // Handle nested tuples
        if (type_info.@"struct".is_tuple) {
            inline for (child) |nested| {
                self.processChild(nested);
            }
            return;
        }
    }

    // =========================================================================
    // Internal: Primitive Rendering
    // =========================================================================

    fn renderText(self: *Self, txt: Text) void {
        self.layout.text(txt.content, .{
            .color = txt.style.color,
            .font_size = txt.style.size,
            .wrap_mode = switch (txt.style.wrap) {
                .none => .none,
                .words => .words,
                .newlines => .newlines,
            },
            .alignment = switch (txt.style.alignment) {
                .left => .left,
                .center => .center,
                .right => .right,
            },
            .decoration = .{
                .underline = txt.style.underline,
                .strikethrough = txt.style.strikethrough,
            },
        }) catch return;
    }

    fn renderInput(self: *Self, inp: Input) void {
        const layout_id = LayoutId.fromString(inp.id);

        // Push dispatch node
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Register as focusable (only if not disabled)
        if (!inp.style.disabled) {
            const focus_id = FocusId.init(inp.id);
            self.dispatch.setFocusable(focus_id);
        }

        // PR 8.4b — seed the pool slot on first render and grab
        // the borrow once for the focus check + focus-register step
        // below. Same create-on-touch shape `Builder.scroll` uses
        // for `ScrollContainer` (PR 8.4a). On capacity exhaustion or
        // OOM the pool returns null; we collapse that to a disabled
        // focus check (matches the pre-PR-8.4b `g.widgets.textInput`
        // null-return semantics) and skip the vtable wire-up below.
        const ti_or_null: ?*TextInputState = if (self.window) |g|
            g.element_states.getOrInsert(
                TextInputState,
                @as(u64, layout_id.id),
                TextInputState.init(g.allocator, DEFAULT_TEXT_INPUT_BOUNDS),
            ) catch null
        else
            null;

        // Check if this input is focused (for border color) - disabled inputs are never focused
        const is_focused = if (inp.style.disabled)
            false
        else if (ti_or_null) |ti|
            ti.isFocused()
        else
            false;

        // Calculate height: use explicit height or auto-size from font metrics
        const chrome = (inp.style.padding + inp.style.border_width) * 2;
        const input_height = inp.style.height orelse blk: {
            // Auto-size: get line height from font metrics
            const line_height = if (self.window) |g|
                if (g.resources.text_system.getMetrics()) |m| m.line_height else 20.0
            else
                20.0; // Fallback
            break :blk line_height + chrome;
        };

        // Calculate inner content size (text area)
        const input_width = inp.style.width orelse 200;
        // When fill_width is true, inner_width will be computed at render time from layout bounds
        const inner_width = if (inp.style.fill_width) 0 else input_width - chrome;
        const inner_height = input_height - chrome;

        // Create the outer box with chrome
        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = if (inp.style.fill_width) SizingAxis.percent(1.0) else SizingAxis.fixed(input_width),
                    .height = SizingAxis.fixed(input_height),
                },
                .padding = Padding.all(@intFromFloat(inp.style.padding + inp.style.border_width)),
            },
            .background_color = inp.style.background,
            .corner_radius = CornerRadius.all(inp.style.corner_radius),
            .border = BorderConfig.all(
                if (is_focused) inp.style.border_color_focused else inp.style.border_color,
                inp.style.border_width,
            ),
        }) catch {
            self.dispatch.popNode();
            return;
        };
        self.layout.closeElement();

        // Store for later text rendering with inner dimensions
        const input_index = self.pending_inputs.items.len;
        self.pending_inputs.append(self.allocator, .{
            .id = inp.id,
            .layout_id = layout_id,
            .style = inp.style,
            .inner_width = inner_width,
            .inner_height = inner_height,
            .on_blur_handler = inp.style.on_blur_handler,
        }) catch {};
        // Mirror into the unified control queue only when the data-plane
        // append landed, so tree-order replay never indexes a slot that
        // failed to allocate (PR 11b.3a).
        if (self.pending_inputs.items.len > input_index) {
            self.enqueuePendingTextWidget(.input, input_index);
        }

        // Register focus with FocusManager (only if not disabled).
        // PR 4: also attach the widget's `Focusable` vtable so the
        // focus manager can drive `focus()` / `blur()` on the
        // underlying `TextInput` without `context/` having to import
        // the widget type. PR 8.4b — the widget pointer is stable
        // across frames because `Window.element_states` heap-
        // allocates each pool entry once per `(EngineType, id_hash)`
        // and never moves it (slots are swap-removed on `.remove`,
        // not relocated on insert). We reuse the borrow grabbed
        // earlier so the focus check and focus-register step share a
        // single pool lookup.
        if (!inp.style.disabled) {
            if (self.window) |g| {
                var handle = FocusHandle.init(inp.id)
                    .tabIndex(inp.style.tab_index)
                    .tabStop(inp.style.tab_stop);
                if (ti_or_null) |ti| {
                    handle = handle.withWidget(ti.focusable());
                }
                g.focus.register(handle);
            }
        }

        self.dispatch.popNode();
    }

    fn renderTextArea(self: *Self, ta: TextAreaPrimitive) void {
        const layout_id = LayoutId.fromString(ta.id);

        // Push dispatch node
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Register as focusable
        const focus_id = FocusId.init(ta.id);
        self.dispatch.setFocusable(focus_id);

        // PR 8.4b — seed the pool slot on first render. See
        // `renderInput` above for the full rationale.
        const ta_state_or_null: ?*TextAreaState = if (self.window) |g|
            g.element_states.getOrInsert(
                TextAreaState,
                @as(u64, layout_id.id),
                TextAreaState.init(g.allocator, DEFAULT_TEXT_AREA_BOUNDS),
            ) catch null
        else
            null;

        // Check if this textarea is focused (for border color)
        const is_focused = if (ta_state_or_null) |text_area|
            text_area.isFocused()
        else
            false;

        // Calculate height: use explicit height or auto-size from rows * line_height
        const chrome = (ta.style.padding + ta.style.border_width) * 2;
        const textarea_height = ta.style.height orelse blk: {
            const line_height = if (self.window) |g|
                if (g.resources.text_system.getMetrics()) |m| m.line_height else 20.0
            else
                20.0;
            const rows_f: f32 = @floatFromInt(ta.style.rows);
            break :blk (line_height * rows_f) + chrome;
        };

        // Calculate dimensions
        const textarea_width = ta.style.width orelse 300;
        // When fill_width is true, inner_width will be computed at render time from layout bounds
        const inner_width = if (ta.style.fill_width) 0 else textarea_width - chrome;
        const inner_height = textarea_height - chrome;

        // Create the outer box with chrome
        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = if (ta.style.fill_width) SizingAxis.percent(1.0) else SizingAxis.fixed(textarea_width),
                    .height = SizingAxis.fixed(textarea_height),
                },
                .padding = Padding.all(@intFromFloat(ta.style.padding + ta.style.border_width)),
            },
            .background_color = ta.style.background,
            .corner_radius = CornerRadius.all(ta.style.corner_radius),
            .border = BorderConfig.all(
                if (is_focused) ta.style.border_color_focused else ta.style.border_color,
                ta.style.border_width,
            ),
        }) catch {
            self.dispatch.popNode();
            return;
        };
        self.layout.closeElement();

        // Store for later text rendering
        const text_area_index = self.pending_text_areas.items.len;
        self.pending_text_areas.append(self.allocator, .{
            .id = ta.id,
            .layout_id = layout_id,
            .style = ta.style,
            .inner_width = inner_width,
            .inner_height = inner_height,
            .on_blur_handler = ta.style.on_blur_handler,
        }) catch {};
        // Mirror into the unified control queue only on a successful
        // data-plane append (PR 11b.3a).
        if (self.pending_text_areas.items.len > text_area_index) {
            self.enqueuePendingTextWidget(.text_area, text_area_index);
        }

        // Register focus with FocusManager. PR 4: attach the widget's
        // `Focusable` vtable so the focus manager can drive the
        // `TextArea`'s `focus()` / `blur()` through the trait without
        // importing the widget type into `context/`. PR 8.4b — reuse
        // the borrow grabbed above so the focus check and the
        // focus-register step share a single pool lookup.
        if (self.window) |g| {
            var handle = FocusHandle.init(ta.id)
                .tabIndex(ta.style.tab_index)
                .tabStop(ta.style.tab_stop);
            if (ta_state_or_null) |text_area| {
                handle = handle.withWidget(text_area.focusable());
            }
            g.focus.register(handle);
        }

        self.dispatch.popNode();
    }

    fn renderCodeEditor(self: *Self, ce: CodeEditorPrimitive) void {
        std.debug.assert(ce.id.len > 0);
        std.debug.assert(ce.style.rows > 0);

        const layout_id = LayoutId.fromString(ce.id);

        // Push dispatch node
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Register as focusable
        const focus_id = FocusId.init(ce.id);
        self.dispatch.setFocusable(focus_id);

        // PR 8.4b — seed the pool slot on first render. See
        // `renderInput` above for the full rationale.
        const ce_state_or_null: ?*CodeEditorState = if (self.window) |g|
            g.element_states.getOrInsert(
                CodeEditorState,
                @as(u64, layout_id.id),
                CodeEditorState.init(g.allocator, DEFAULT_CODE_EDITOR_BOUNDS),
            ) catch null
        else
            null;

        // Check if this code editor is focused (for border color)
        const is_focused = if (ce_state_or_null) |editor|
            editor.isFocused()
        else
            false;

        // Calculate height: use explicit height or auto-size from rows * line_height
        const chrome = (ce.style.padding + ce.style.border_width) * 2;
        const editor_height = ce.style.height orelse blk: {
            const line_height = if (self.window) |g|
                if (g.resources.text_system.getMetrics()) |m| m.line_height else 20.0
            else
                20.0;
            const rows_f: f32 = @floatFromInt(ce.style.rows);
            break :blk (line_height * rows_f) + chrome;
        };

        // Calculate dimensions
        const editor_width = ce.style.width orelse 400;
        const inner_width = editor_width - chrome;
        const inner_height = editor_height - chrome;

        // Create the outer box with chrome
        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.fixed(editor_width),
                    .height = SizingAxis.fixed(editor_height),
                },
                .padding = Padding.all(@intFromFloat(ce.style.padding + ce.style.border_width)),
            },
            .background_color = ce.style.background,
            .corner_radius = CornerRadius.all(ce.style.corner_radius),
            .border = BorderConfig.all(
                if (is_focused) ce.style.border_color_focused else ce.style.border_color,
                ce.style.border_width,
            ),
        }) catch {
            self.dispatch.popNode();
            return;
        };
        self.layout.closeElement();

        // Store for later rendering
        const code_editor_index = self.pending_code_editors.items.len;
        self.pending_code_editors.append(self.allocator, .{
            .id = ce.id,
            .layout_id = layout_id,
            .style = ce.style,
            .inner_width = inner_width,
            .inner_height = inner_height,
            .on_blur_handler = ce.style.on_blur_handler,
        }) catch {};
        // Mirror into the unified control queue only on a successful
        // data-plane append (PR 11b.3a).
        if (self.pending_code_editors.items.len > code_editor_index) {
            self.enqueuePendingTextWidget(.code_editor, code_editor_index);
        }

        // Register focus with FocusManager. PR 4: attach the widget's
        // `Focusable` vtable — same pattern as `renderInput` /
        // `renderTextArea` above. The vtable lives in static storage,
        // shared by all `CodeEditorState` instances. PR 8.4b — reuse
        // the borrow grabbed above so the focus check and the
        // focus-register step share a single pool lookup.
        if (self.window) |g| {
            var handle = FocusHandle.init(ce.id)
                .tabIndex(ce.style.tab_index)
                .tabStop(ce.style.tab_stop);
            if (ce_state_or_null) |editor| {
                handle = handle.withWidget(editor.focusable());
            }
            g.focus.register(handle);
        }

        self.dispatch.popNode();
    }

    fn renderSpacer(self: *Self, spc: Spacer) void {
        _ = spc;
        self.layout.openElement(.{
            .id = self.generateId(),
            .layout = .{
                .sizing = .{
                    .width = SizingAxis.grow(),
                    .height = SizingAxis.grow(),
                },
            },
        }) catch return;
        self.layout.closeElement();
    }

    fn renderButton(self: *Self, btn: Button) void {
        // Use explicit ID if provided, otherwise derive from label
        const layout_id = if (btn.id) |id| LayoutId.fromString(id) else LayoutId.fromString(btn.label);

        // Push dispatch node for this button
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Check hover state
        const is_hovered = btn.style.enabled and
            if (self.window) |g| g.isHovered(layout_id.id) else false;

        const bg = switch (btn.style.style) {
            .primary => if (!btn.style.enabled)
                Color.rgb(0.5, 0.7, 1.0)
            else if (is_hovered)
                Color.rgb(0.3, 0.6, 1.0) // Lighter on hover
            else
                Color.rgb(0.2, 0.5, 1.0),
            .secondary => if (is_hovered)
                Color.rgb(0.82, 0.82, 0.82) // Darker on hover
            else
                Color.rgb(0.9, 0.9, 0.9),
            .danger => if (is_hovered)
                Color.rgb(1.0, 0.4, 0.4) // Lighter on hover
            else
                Color.rgb(0.9, 0.3, 0.3),
        };
        const fg = switch (btn.style.style) {
            .primary, .danger => Color.white,
            .secondary => Color.rgb(0.3, 0.3, 0.3),
        };

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = Sizing.fitContent(),
                .padding = Padding.symmetric(24, 10),
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = bg,
            .corner_radius = CornerRadius.all(6),
        }) catch {
            self.dispatch.popNode();
            return;
        };

        self.layout.text(btn.label, .{
            .color = fg,
            .font_size = self.theme().font_size_base,
        }) catch {};

        self.layout.closeElement();

        // Register click handler with dispatch tree
        if (btn.on_click) |callback| {
            if (btn.style.enabled) {
                self.dispatch.onClick(callback);
            }
        }

        self.dispatch.popNode();
    }

    fn renderButtonHandler(self: *Self, btn: ButtonHandler) void {
        // Use explicit ID if provided, otherwise derive from label
        const layout_id = if (btn.id) |id| LayoutId.fromString(id) else LayoutId.fromString(btn.label);

        // Push dispatch node for this button
        _ = self.dispatch.pushNode();
        self.dispatch.setLayoutId(layout_id.id);

        // Check hover state
        const is_hovered = btn.style.enabled and
            if (self.window) |g| g.isHovered(layout_id.id) else false;

        const bg = switch (btn.style.style) {
            .primary => if (!btn.style.enabled)
                Color.rgb(0.5, 0.7, 1.0)
            else if (is_hovered)
                Color.rgb(0.3, 0.6, 1.0) // Lighter on hover
            else
                Color.rgb(0.2, 0.5, 1.0),
            .secondary => if (is_hovered)
                Color.rgb(0.82, 0.82, 0.82) // Darker on hover
            else
                Color.rgb(0.9, 0.9, 0.9),
            .danger => if (is_hovered)
                Color.rgb(1.0, 0.4, 0.4) // Lighter on hover
            else
                Color.rgb(0.9, 0.3, 0.3),
        };
        const fg = switch (btn.style.style) {
            .primary, .danger => Color.white,
            .secondary => Color.rgb(0.3, 0.3, 0.3),
        };

        self.layout.openElement(.{
            .id = layout_id,
            .layout = .{
                .sizing = Sizing.fitContent(),
                .padding = Padding.symmetric(24, 10),
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .background_color = bg,
            .corner_radius = CornerRadius.all(6),
        }) catch {
            self.dispatch.popNode();
            return;
        };

        self.layout.text(btn.label, .{
            .color = fg,
            .font_size = self.theme().font_size_base,
        }) catch {};

        self.layout.closeElement();

        // Register handler-based click handler
        if (btn.style.enabled) {
            self.dispatch.onClickHandler(btn.handler);
        }

        self.dispatch.popNode();
    }

    fn renderSvg(self: *Self, prim: SvgPrimitive) void {
        // Generate a unique layout ID for this SVG instance
        const layout_id = self.generateId();

        // Use layout engine's svg method - this creates the element AND
        // ensures the SVG command is emitted inline with other primitives
        // for correct z-ordering
        self.layout.svg(layout_id, prim.width, prim.height, .{
            .path = prim.path,
            .color = prim.color,
            .stroke_color = prim.stroke_color,
            .stroke_width = prim.stroke_width,
            .has_fill = prim.has_fill,
            .viewbox = prim.viewbox,
        }) catch return;
    }

    fn renderImage(self: *Self, prim: ImagePrimitive) void {
        // Generate a unique layout ID for this image instance
        const layout_id = self.generateId();

        // Convert fit enum to u8
        const fit_u8: u8 = switch (prim.fit) {
            .contain => 0,
            .cover => 1,
            .fill => 2,
            .none => 3,
            .scale_down => 4,
        };

        // Convert corner radius to layout type if present
        const corner_rad: ?CornerRadius = if (prim.corner_radius) |cr|
            cr
        else
            null;

        // Use layout engine's image method - this creates the element AND
        // ensures the image command is emitted inline with other primitives
        // for correct z-ordering
        self.layout.image(layout_id, prim.width, prim.height, .{
            .source = prim.source,
            .width = prim.width,
            .height = prim.height,
            .fit = fit_u8,
            .corner_radius = corner_rad,
            .tint = prim.tint,
            .grayscale = prim.grayscale,
            .opacity = prim.opacity,
            .placeholder_color = prim.placeholder_color,
        }) catch return;
    }

    fn renderActionHandlerRef(self: *Self, ah: ActionHandlerRefPrimitive) void {
        self.dispatch.onActionHandlerRaw(ah.action_type, ah.handler);
    }

    fn renderKeyContext(self: *Self, ctx: KeyContextPrimitive) void {
        self.dispatch.setKeyContext(ctx.context);
    }

    fn renderActionHandler(self: *Self, handler: ActionHandlerPrimitive) void {
        const node_id = self.dispatch.currentNode();
        if (self.dispatch.getNode(node_id)) |node| {
            node.getOrCreateListeners(self.allocator).action_listeners.append(self.allocator, .{
                .action_type = handler.action_type,
                .callback = handler.callback,
            }) catch @panic("dispatch: action listener registration failed (OOM)");
        }
    }

    // =========================================================================
    // Internal: ID Generation
    // =========================================================================

    /// Generate a stable, parent-scoped layout id for an element the author
    /// did not name explicitly (PR 11b.2a).
    ///
    /// The old implementation was a flat per-frame counter
    /// (`LayoutId.fromInt(++id_counter)`). That had two footguns: (1) it was
    /// global, so inserting or removing *any* element shifted the auto-id of
    /// *every* later element on reflow, so hover / focus / animation state
    /// jumped to the wrong element; and (2) components that fell back to a
    /// content string (e.g. a `Button` deriving `id = self.label`) collided
    /// when two same-content siblings existed.
    ///
    /// The new id is `hash(parent_layout_id, sibling_index)` via
    /// `LayoutId.childIndexed`. The parent is the currently-open element,
    /// already on the dispatch stack at this point (this runs *before* the
    /// new element pushes its own node), so reading it is free. The sibling
    /// index is the parent dispatch node's `auto_child_counter`, which counts
    /// only `generateId` calls under that parent. Two consequences:
    ///   - Reflow in a *sibling* subtree no longer perturbs these ids (the
    ///     blast radius of an insert/remove is now one parent's children).
    ///   - Explicit-id siblings don't bump the counter, so adding a named
    ///     element next to auto-id'd ones leaves their indices untouched.
    pub fn generateId(self: *Self) LayoutId {
        // The seed must stay non-empty or the auto-id hash domain collapses
        // onto the parent id; this is a critical, surprising invariant.
        comptime std.debug.assert(AUTO_ID_SEED.len > 0);

        const parent_node_id = self.dispatch.currentNode();
        if (self.dispatch.getNode(parent_node_id)) |parent| {
            const sibling_index = parent.auto_child_counter;
            std.debug.assert(sibling_index < MAX_AUTO_SIBLINGS);
            parent.auto_child_counter += 1;
            // Parents always reach here via `boxWithLayoutIdImpl`, which calls
            // `setLayoutId` immediately after `pushNode` and before any child
            // renders, so `layout_id` is populated; `orelse 0` is defensive.
            const parent_layout_id = parent.layout_id orelse 0;
            return LayoutId.childIndexed(parent_layout_id, AUTO_ID_SEED, sibling_index);
        }

        // Root scope: no element is open yet (e.g. the user's top-level box has
        // no explicit id). Fall back to the per-frame flat counter, still mixed
        // through `childIndexed` so the hash domain matches the nested case.
        self.id_counter += 1;
        std.debug.assert(self.id_counter < MAX_AUTO_SIBLINGS);
        return LayoutId.childIndexed(0, AUTO_ID_SEED, self.id_counter);
    }
};

// PR 11b.2a — hierarchical auto-id tests.
//
// Goal: prove the three properties the parent-scoped scheme buys us, using a
// `Builder` driven over a real `DispatchTree` (the only collaborator
// `generateId` reads). Methodology: open parent nodes by hand on the dispatch
// stack — exactly what `boxWithLayoutIdImpl` does at element-open — then call
// `generateId` and compare the resulting hashes.
fn testBuilderHarness(
    allocator: std.mem.Allocator,
    engine: *LayoutEngine,
    scene_ptr: *Scene,
    tree: *DispatchTree,
) Builder {
    engine.* = LayoutEngine.init(allocator);
    scene_ptr.* = Scene.init(allocator);
    tree.* = DispatchTree.init(allocator);
    return Builder.init(allocator, engine, scene_ptr, tree);
}

test "generateId: same-parent siblings never collide" {
    const gpa = std.testing.allocator;
    var engine: LayoutEngine = undefined;
    var scene_buf: Scene = undefined;
    var tree: DispatchTree = undefined;
    var builder = testBuilderHarness(gpa, &engine, &scene_buf, &tree);
    defer engine.deinit();
    defer scene_buf.deinit();
    defer tree.deinit();

    // Open a parent, as `boxWithLayoutIdImpl` does (pushNode → setLayoutId).
    _ = tree.pushNode();
    tree.setLayoutId(LayoutId.fromString("parent").id);

    // Two auto-id'd children with identical content still get distinct ids —
    // the flat-counter scheme relied on global uniqueness; the parent-scoped
    // scheme gets it from the per-parent sibling index instead.
    const first = builder.generateId();
    const second = builder.generateId();
    try std.testing.expect(first.id != second.id);
}

test "generateId: stable across frames for the same tree shape" {
    const gpa = std.testing.allocator;
    var engine: LayoutEngine = undefined;
    var scene_buf: Scene = undefined;
    var tree: DispatchTree = undefined;
    var builder = testBuilderHarness(gpa, &engine, &scene_buf, &tree);
    defer engine.deinit();
    defer scene_buf.deinit();
    defer tree.deinit();

    const parent_hash = LayoutId.fromString("parent").id;

    // Frame 1.
    _ = tree.pushNode();
    tree.setLayoutId(parent_hash);
    const frame1_a = builder.generateId();
    const frame1_b = builder.generateId();
    tree.popNode();

    // Frame 2: same tree shape ⇒ identical auto-ids. This is what keeps
    // hover / focus / animation state pinned to the same element across
    // frames; the flat counter only held this by luck of unchanged order.
    tree.reset();
    _ = tree.pushNode();
    tree.setLayoutId(parent_hash);
    const frame2_a = builder.generateId();
    const frame2_b = builder.generateId();

    try std.testing.expectEqual(frame1_a.id, frame2_a.id);
    try std.testing.expectEqual(frame1_b.id, frame2_b.id);
}

test "generateId: same sibling index under different parents does not collide" {
    const gpa = std.testing.allocator;
    var engine: LayoutEngine = undefined;
    var scene_buf: Scene = undefined;
    var tree: DispatchTree = undefined;
    var builder = testBuilderHarness(gpa, &engine, &scene_buf, &tree);
    defer engine.deinit();
    defer scene_buf.deinit();
    defer tree.deinit();

    // First child (index 0) of parent A.
    _ = tree.pushNode();
    tree.setLayoutId(LayoutId.fromString("parent-a").id);
    const a0 = builder.generateId();
    tree.popNode();

    // First child (index 0) of parent B. Same sibling index, different parent
    // ⇒ different hash, because the parent's layout id seeds the hash.
    _ = tree.pushNode();
    tree.setLayoutId(LayoutId.fromString("parent-b").id);
    const b0 = builder.generateId();
    tree.popNode();

    try std.testing.expect(a0.id != b0.id);
}
