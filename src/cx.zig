//! `Cx` — the unified rendering context.
//!
//! `Cx` is the single entry point that render functions and components
//! receive each frame. It groups:
//!
//!   * State access — `cx.state(AppState)` / `cx.stateConst(AppState)`.
//!   * Rendering    — `cx.render(ui.box(...))`.
//!   * Handlers     — `cx.on(method, options)` and `cx.deferCommand`.
//!   * Sub-namespaces: `cx.lists`, `cx.animations`,
//!                    `cx.entities`, `cx.focus`, and
//!                    `cx.element_states` (keyed pool of
//!                    per-element retained state).
//!
//! `cx.on` accepts four method shapes, detected from the signature:
//! `fn(*State)`, `fn(*State, Arg)`, `fn(*State, *Window)`, and
//! `fn(*State, Arg, *Window)`. See `context/handler.zig`.
//!
//! Examples live in `examples/` and the integration tests under
//! `cx_tests.zig`.

const std = @import("std");

// Pull in the split-out test file so `zig build test` discovers its
// tests through the standard reachability graph. The block runs at
// comptime and produces no runtime cost. The pattern tests live
// outside `cx.zig` to keep this file under the 800-line budget — see
// `cx_tests.zig` for the bodies.
comptime {
    _ = @import("cx_tests.zig");
}

// Core imports
// The platform module is imported once at file scope rather than inside each
// method that needs it; an in-body `@import` makes it easy to miss that a
// method reaches into backend-specific namespaces.
const platform_mod = @import("platform/mod.zig");
const window_mod = @import("context/window.zig");
const Window = window_mod.Window;
const ui_mod = @import("ui/mod.zig");
const Builder = ui_mod.Builder;
const AccessibleConfig = ui_mod.AccessibleConfig;
const a11y = @import("accessibility/accessibility.zig");
const change_tracker_mod = @import("context/change_tracker.zig");
const handler_mod = @import("context/handler.zig");
const entity_mod = @import("context/entity.zig");
// Widget engine-state pools — the `cx.textField` / `cx.textAreaWidget` /
// `cx.codeEditorWidget` / `cx.scrollView` accessors keyed off these.
// List and table state types are imported by `cx/lists.zig`, since callers
// go through `cx.lists.*`.
const text_field_mod = @import("widgets/text_input_state.zig");
const text_area_mod = @import("widgets/text_area_state.zig");
const code_editor_mod = @import("widgets/code_editor_state.zig");
const scroll_view_mod = @import("widgets/scroll_container.zig");

// `cx.scrollView(id)` goes through
// `Window.element_states.getOrInsert(ScrollContainer, hash, init)`.
// `LayoutId.fromString(id).id` is the u32 hash key, matching every
// other element-state path that comes from a string id (`TextInputState` /
// `TextAreaState` / `CodeEditorState`).
const layout_id_mod = @import("layout/layout_id.zig");
const LayoutId = layout_id_mod.LayoutId;
const Box = ui_mod.Box;

// Text measurement types
const text_mod = @import("text/mod.zig");
pub const TextMeasurement = text_mod.TextMeasurement;

// Animation module — only `hashString` is needed on `cx.zig` itself
// (for `cx.changed`'s key hashing). Callers reach the animation config
// types through `cx.animations.*` or the `animation.*` namespace directly.
const animation_mod = @import("animation/mod.zig");

const Handler = handler_mod.Handler;
pub const typeId = handler_mod.typeId;

// Entity types — only `EntityId` is needed here;
// the user-facing `Entity` / `EntityMap` / `EntityContext` generics
// route through `cx.entities.*` (which imports them locally).
const EntityId = entity_mod.EntityId;

// UI types (re-exported from root.zig for users)
const Theme = ui_mod.Theme;

// Sub-namespace modules. Each exposes a zero-sized struct
// that lives as a field on `Cx`; methods on those structs recover
// `*Cx` via `@fieldParentPtr`, giving the `cx.lists.uniform(...)` /
// `cx.animations.spring(...)` call shape without extra storage
// (CLAUDE.md §10 — don't take aliases) and without extra parens.
const lists_mod = @import("cx/lists.zig");
const animations_mod = @import("cx/animations.zig");
const entities_mod = @import("cx/entities.zig");
const focus_mod = @import("cx/focus.zig");
const element_states_mod = @import("cx/element_states.zig");

/// `Cx` — see the file-level doc.
pub const Cx = struct {
    _allocator: std.mem.Allocator,

    /// Internal runtime coordinator (manages scene, layout, widgets, etc.)
    _window: *Window,

    /// Layout builder
    _builder: *Builder,

    /// Type-erased state pointer (set at app init)
    state_ptr: *anyopaque,

    /// Type ID for runtime type checking
    state_type_id: usize,

    /// Internal ID counter for generated IDs
    id_counter: u32 = 0,

    // Sub-namespaces. Zero-sized fields default-initialised so
    // call-site struct literals (e.g. in `runtime/window_context.zig`)
    // need not mention them.
    lists: lists_mod.Lists = .{},
    animations: animations_mod.Animations = .{},
    entities: entities_mod.Entities = .{},
    focus: focus_mod.Focus = .{},

    // Surfaces `Window.element_states` (the keyed pool of per-element
    // retained state) on `Cx`. Same zero-sized namespace shape as the
    // sibling fields above, so widgets use the public
    // `cx.element_states.*` surface instead of reaching through
    // `cx._window.element_states`.
    element_states: element_states_mod.ElementStates = .{},

    /// Paired runtime container operations for validated dynamic trees.
    dynamic: Dynamic = .{},

    pub const Dynamic = struct {
        _align: [0]usize = .{},

        inline fn cx(self: *Dynamic) *Cx {
            return @fieldParentPtr("dynamic", self);
        }

        pub fn beginBox(self: *Dynamic, layout_id: LayoutId, style: Box) !void {
            const context = self.cx();
            std.debug.assert(layout_id.id != 0);
            std.debug.assert(layout_id.base_id != 0);
            try context._builder.beginDynamicBox(layout_id, style);
        }

        pub fn endBox(self: *Dynamic) void {
            const context = self.cx();
            std.debug.assert(context._builder.dynamic_box_count > 0);
            std.debug.assert(context._builder.dynamic_box_count <= ui_mod.Builder.MAX_DYNAMIC_BOX_DEPTH);
            context._builder.endDynamicBox();
        }
    };

    const Self = @This();

    // =========================================================================
    // State Access
    // =========================================================================

    /// Mutable access to the application state. `T` must be the type passed
    /// to `run()` / `App()`. Debug and ReleaseSafe check this and panic with
    /// both type names; ReleaseFast and ReleaseSmall compile the check out,
    /// matching `cx.on` (contract "Approved decisions" item 2).
    pub fn state(self: *Self, comptime T: type) *T {
        if (comptime std.debug.runtime_safety) {
            if (self.state_type_id != typeId(T)) {
                handler_mod.reportMismatch("cx.state({s}): the root state is {s}", .{
                    @typeName(T), handler_mod.argTypeName(self.state_type_id),
                });
            }
        }
        return @ptrCast(@alignCast(self.state_ptr));
    }

    /// Read-only access to the application state.
    pub fn stateConst(self: *Self, comptime T: type) *const T {
        return self.state(T);
    }

    // =========================================================================
    // Window Operations
    // =========================================================================

    /// Get the current window size in logical pixels.
    pub fn windowSize(self: *Self) struct { width: f32, height: f32 } {
        return .{
            .width = self._window.width,
            .height = self._window.height,
        };
    }

    /// Get the display scale factor (e.g., 2.0 for Retina).
    pub fn scaleFactor(self: *Self) f32 {
        return self._window.scale_factor;
    }

    /// Set the window title.
    ///
    /// The parameter is `[]const u8`, matching the platform contract's
    /// `setTitle` (see `platform/contract.zig`). It is not `[:0]const u8`
    /// because no backend requires a sentinel and callers cannot always
    /// produce one; every backend copies into its own buffer and adds the
    /// terminator itself.
    ///
    /// Nothing in-tree calls this method, so `root.zig` forces analysis of
    /// `Cx` method bodies to keep it compiling.
    pub fn setTitle(self: *Self, title: []const u8) void {
        if (self._window.platform_window) |pw| pw.setTitle(title);
    }

    /// Change the font at runtime. Clears glyph / shape caches and
    /// triggers a re-render.
    pub fn setFont(self: *Self, name: []const u8, size: f32) !void {
        try self._window.setFont(name, size);
    }

    /// Set the glass / blur effect style for the window.
    ///
    /// Glass is a platform-specific capability, not part of the common window
    /// contract, so it is gated on the backend's comptime
    /// `capabilities.glass_effects`. Backends that cannot composite a
    /// translucent backdrop (Wayland has no such protocol; the browser path
    /// needs CSS the host does not yet apply) compile this out entirely.
    ///
    /// The call goes through the selected `PlatformWindow` directly, with no
    /// cast to a backend-concrete window type, and there is one canonical
    /// `GlassStyle` shared by every backend, so tag values cannot disagree.
    pub fn setGlassStyle(
        self: *Self,
        style: platform_mod.GlassStyle,
        opacity: f64,
        corner_radius: f64,
    ) void {
        if (comptime !platform_mod.Platform.capabilities.glass_effects) return;

        std.debug.assert(opacity >= 0.0 and opacity <= 1.0);
        std.debug.assert(corner_radius >= 0.0);

        // Capture name `pw` is disambiguated from the
        // `pub fn window(self: *Self)` accessor.
        if (self._window.platform_window) |pw| {
            pw.setGlassStyle(style, opacity, corner_radius);
        }
    }

    /// Close the window (and exit the application).
    ///
    /// `close` is part of the common window contract on every backend, so this
    /// needs no web special case. A browser cannot close a tab it did
    /// not open — `capabilities.can_close_window` is `false` there — but the
    /// web window still records the request so `isClosed()` is truthful and
    /// Gooey can stop driving frames.
    pub fn close(self: *Self) void {
        // Capture is `pw`, not `window`, to avoid shadowing the
        // `pub fn window(self: *Self)` accessor declared on `Cx`.
        if (self._window.platform_window) |pw| {
            pw.close();
        }
    }

    /// Quit the application immediately. No-op on web.
    pub fn quit(self: *Self) void {
        self._window.quit();
    }

    // =========================================================================
    // Handlers — `on` / `deferCommand`
    // =========================================================================

    /// Build a `Handler` from a method. The method's shape is detected at
    /// comptime: `fn(*State)`, `fn(*State, Arg)`, `fn(*State, *Window)`, or
    /// `fn(*State, Arg, *Window)`. `options` accepts only `.arg`, coerced to
    /// the method's `Arg` (8 bytes at most), and `.entity`, an `Entity(State)`
    /// whose data the method runs on. Without `.entity`, `State` must be the
    /// root state; Debug and ReleaseSafe check this here and panic naming the
    /// method. The UI re-renders after the method returns.
    ///
    /// ```zig
    /// Button{ .label = "+", .on_click = cx.on(AppState.increment, .{}) }
    /// Button{ .label = "5", .on_click = cx.on(AppState.setStep, .{ .arg = 5 }) }
    /// Select{ .on_select = cx.on(AppState.selectFruit, .{}), ... } // index bound per option
    /// ```
    pub fn on(self: *Self, comptime method: anytype, options: anytype) Handler {
        return handler_mod.bind(self._window, method, options);
    }

    /// Schedule a method to run after current event handling completes. Use
    /// for modal dialogs and other operations that cannot run mid-event.
    /// Takes the same method shapes and options as `cx.on`. Named to avoid
    /// the `defer` keyword.
    pub fn deferCommand(self: *Self, comptime method: anytype, options: anytype) void {
        self._window.deferCommand(method, options);
    }

    // =========================================================================
    // Async work — `std.Io.Queue(T)` pattern
    // =========================================================================
    //
    // Cross-thread communication uses `std.Io.Queue(T)` — a bounded,
    // lock-free channel with static backing storage. Background work
    // pushes typed results in; the render loop drains them without
    // blocking. See `examples/` for end-to-end usage.

    /// Non-blocking drain of an `std.Io.Queue(T)` into the caller's
    /// buffer. Returns an empty slice if no results are available, so
    /// it's safe to call every frame from `render`.
    pub fn drainQueue(self: *Self, comptime T: type, queue: *std.Io.Queue(T), buffer: []T) []const T {
        std.debug.assert(buffer.len > 0);
        // Non-blocking: min=0 guarantees immediate return.
        const count = queue.get(self.io(), buffer, 0) catch return buffer[0..0];
        return buffer[0..count];
    }

    // =========================================================================
    // Structured cancellation — `std.Io.Group` lifecycle
    // =========================================================================
    //
    // App-level groups: register here, cancelled at window close.
    // Entity-scoped groups: see `cx.entities.attachCancel`. Group
    // cancellation blocks; only run it at teardown, never mid-frame.

    /// Register a cancel group for automatic cancellation on window
    /// close. Pair with `unregisterCancelGroup` if the async work
    /// completes normally.
    pub fn registerCancelGroup(self: *Self, group: *std.Io.Group) void {
        self._window.registerCancelGroup(group);
    }

    /// Unregister a cancel group (e.g. work completed normally).
    pub fn unregisterCancelGroup(self: *Self, group: *std.Io.Group) void {
        self._window.unregisterCancelGroup(group);
    }

    // Deprecated: see `cx.entities.attachCancel` / `detachCancel`.
    pub fn attachEntityCancelGroup(self: *Self, id: EntityId, group: *std.Io.Group) void {
        self.entities.attachCancel(id, group);
    }
    pub fn detachEntityCancelGroup(self: *Self, id: EntityId) void {
        self.entities.detachCancel(id);
    }

    // =========================================================================
    // Text measurement
    // =========================================================================

    /// Options for `measureText`. `null` fields fall back to "no
    /// wrapping" / "current font size" respectively; `weight` and `italic`
    /// pick the face text with that `TextStyle` renders in. Aliased from
    /// `gooey.text.MeasureTextOptions` so the value type a downstream
    /// needs to *store* a measurement+options pair lives on the public
    /// text surface alongside `TextMeasurement`, while
    /// `Cx.MeasureTextOptions` keeps working unchanged.
    pub const MeasureTextOptions = text_mod.MeasureTextOptions;

    /// Measure a text string with optional wrapping, font size, weight, and
    /// slant. Uses the platform text shaper (CoreText / HarfBuzz / browser)
    /// and the face that renders the same `TextStyle`, so kerning, bold
    /// advances, and wrapping match rendered output.
    pub fn measureText(self: *Self, text_content: []const u8, opts: MeasureTextOptions) !TextMeasurement {
        std.debug.assert(opts.font_size == null or opts.font_size.? > 0);
        std.debug.assert(opts.max_width == null or opts.max_width.? > 0);

        const ts = self._window.getTextSystem();
        const variant = text_mod.FontVariant.init(opts.weight, opts.italic);

        if (opts.font_size) |requested_size| {
            const metrics = ts.getMetrics() orelse return error.NoFontLoaded;
            std.debug.assert(metrics.point_size > 0);
            const scale = requested_size / metrics.point_size;
            std.debug.assert(scale > 0);

            // Scale max_width into base-font units so wrapping breaks at
            // the correct character positions, then scale the result back.
            const base_max_width: ?f32 = if (opts.max_width) |mw| mw / scale else null;
            var m = try ts.measureTextEx(.app, text_content, variant, base_max_width);
            m.width *= scale;
            m.height *= scale;
            return m;
        }

        return ts.measureTextEx(.app, text_content, variant, opts.max_width);
    }

    // =========================================================================
    // Entities — reach for `cx.entities.*` directly.
    // =========================================================================

    /// Request a UI re-render.
    pub fn notify(self: *Self) void {
        self._window.requestRender();
    }

    // =========================================================================
    // Focus — reach for `cx.focus.*` directly. `cx.focus.widget(id)`
    // focuses text fields and text areas alike.
    // =========================================================================

    // Widget access (for advanced use cases). Each returns `null` if
    // no widget with that id has been registered. The returned types
    // are the *engine* state objects (`TextInputState`, `TextAreaState`,
    // `CodeEditorState`) — not the user-facing `TextInput` / `TextArea`
    // declarative components in `components/src/`.
    //
    // Storage lives on `Window.element_states`. Each accessor
    // here is a read-only `get` keyed by `LayoutId.id`: the matching
    // `Builder.render*` site is the create-on-touch boundary, so by
    // the time application code reaches for the engine state on a
    // widget that just rendered the slot is already populated. The
    // accessors stay `?*T` for the case where the widget hasn't
    // mounted yet (e.g. a callback firing before the first render).
    pub fn textField(self: *Self, id: []const u8) ?*text_field_mod.TextInputState {
        return self._window.widgetState(text_field_mod.TextInputState, id);
    }
    pub fn textAreaWidget(self: *Self, id: []const u8) ?*text_area_mod.TextAreaState {
        return self._window.widgetState(text_area_mod.TextAreaState, id);
    }
    pub fn codeEditorWidget(self: *Self, id: []const u8) ?*code_editor_mod.CodeEditorState {
        return self._window.widgetState(code_editor_mod.CodeEditorState, id);
    }
    pub fn scrollView(self: *Self, id: []const u8) ?*scroll_view_mod.ScrollContainer {
        // Storage lives on `Window.element_states`. Hash the string id once at
        // the boundary; subsequent frames hit the cached pointer
        // through `getOrInsertWith`, whose `make` factory runs only on
        // the seeding miss — never on a hit. Failure modes (OOM /
        // `error.ElementStatesAtCapacity`) collapse to `null` so the
        // public surface stays an optional `?*ScrollContainer`.
        const hash: u64 = @as(u64, LayoutId.fromString(id).id);
        const g = self._window;
        return g.element_states.getOrInsertWith(
            scroll_view_mod.ScrollContainer,
            hash,
            g.allocator,
            scroll_view_mod.ScrollContainer.init,
        ) catch null;
    }

    /// Render an element tree. Works with any renderable — `ui.*`
    /// primitives, layout containers, and components whose `render`
    /// accepts `*Cx`.
    pub fn render(self: *Self, element: anytype) void {
        self._builder.processChildren(element);
    }

    /// Resolve an element id *once*. An explicit string hashes
    /// through `LayoutId.fromString`; a null id falls back to the
    /// parent-scoped auto id (`Builder.generateId`).
    ///
    /// Components resolve identity once and reuse it for accessibility and
    /// `ui.box_with_layout_id`. When `id` is null, this calls `generateId` while
    /// the parent is still open so identity remains parent-scoped.
    pub fn idFor(self: *Self, id: ?[]const u8) LayoutId {
        if (id) |string_id| return LayoutId.fromString(string_id);
        return self._builder.generateId();
    }

    /// Render a single child component immediately. Unlike
    /// `Builder.with` (which passes `*Builder`), this routes through the
    /// `*Cx`-aware dispatch so the child's `render(self, *Cx)` is
    /// invoked. Retains `Builder.with`'s compile-time guard so a
    /// non-renderable argument fails the build rather than silently
    /// no-ops (CLAUDE.md §17: errors are not silently discarded).
    pub fn with(self: *Self, component: anytype) void {
        const Component = @TypeOf(component);
        if (@typeInfo(Component) == .@"struct" and @hasDecl(Component, "render")) {
            self._builder.processChildren(component);
        } else {
            @compileError("with() requires a struct with a `render` method");
        }
    }

    /// The owning `Window`, or null if the builder has none bound.
    /// Mirrors `Builder.getGooey`; prefer `cx.window()` when the window
    /// is known to be present (it asserts non-null).
    pub fn getGooey(self: *Self) ?*Window {
        return self._builder.getGooey();
    }

    // =========================================================================
    // Accessibility
    // =========================================================================

    /// Begin an accessible element. Returns true if a11y is active
    /// and the element was pushed; pair with `accessibleEnd()` when so.
    pub fn accessible(self: *Self, config: AccessibleConfig) bool {
        return self._builder.accessible(config);
    }

    /// End the current accessible element. Only call after
    /// `accessible()` returned true.
    pub fn accessibleEnd(self: *Self) void {
        self._builder.accessibleEnd();
    }

    /// Announce a message to screen readers. `.polite` for routine
    /// updates, `.assertive` for critical alerts.
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        self._builder.announce(message, priority);
    }

    /// True when accessibility is currently enabled.
    pub fn isA11yEnabled(self: *Self) bool {
        return self._builder.isA11yEnabled();
    }

    // Internal access (advanced use cases / migration). Lifetime is
    // tied to `*Cx` — don't store these across frames.
    pub fn window(self: *Self) *Window {
        return self._window;
    }
    pub fn builder(self: *Self) *Builder {
        return self._builder;
    }
    /// Reserve the storage needed by bounded immediate-mode canvases.
    pub fn reserve_canvas(self: *Self, options: struct {
        canvas_count: u32,
        quad_count: u32,
    }) !void {
        std.debug.assert(options.canvas_count > 0);
        std.debug.assert(options.quad_count > 0);
        try self._window.reserve_canvas_quads(options.quad_count);
        try self._builder.reserve_pending_canvas(options.canvas_count);
    }
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self._allocator;
    }
    /// IO interface for filesystem access and async work. Mirrors
    /// `cx.allocator()` — same lifetime as `*Cx`.
    pub fn io(self: *Self) std.Io {
        return self._window.io;
    }

    /// Set the theme for this context and all child components. Call
    /// once at the top of `render`; children auto-inherit colors.
    pub fn setTheme(self: *Self, theme_ptr: *const Theme) void {
        self._builder.setTheme(theme_ptr);
    }

    /// Current theme, falling back to the light theme if none was set.
    pub fn theme(self: *Self) *const Theme {
        return self._builder.theme();
    }

    // =========================================================================
    // Animations — reach for `cx.animations.*` directly.
    // =========================================================================

    // =========================================================================
    // Change detection
    // =========================================================================

    /// True when the value at `key` differs from the previous frame.
    /// First call for a key returns false — there's no prior value to
    /// diff against. Replaces the module-level `var last_foo` /
    /// manual-diff pattern.
    ///
    /// Value comparison is structural (see `change_tracker.hashValue`):
    /// structs diff field-by-field (padding-safe) and slices — including
    /// `[]const u8` strings — diff by *content*, so an in-place string edit
    /// registers as changed and an identical string at a new address does
    /// not. Non-slice pointers still compare by address (identity), not
    /// pointee, since following them could dangle.
    pub fn changed(self: *Self, comptime key: []const u8, value: anytype) bool {
        const key_hash = comptime animation_mod.hashString(key);
        const value_hash = change_tracker_mod.hashValue(@TypeOf(value), value);
        // `change_tracker` is a peer field on `Window`, not part of any
        // catch-all retained-storage namespace.
        return self._window.change_tracker.changed(key_hash, value_hash);
    }

    // =========================================================================
    // Lists / tables — reach for `cx.lists.*` directly. The
    // `DataTableCallbacks(Cx)` generic type lives at
    // `cx.lists.Lists.DataTableCallbacks(Cx)` as its sole canonical home.
    // =========================================================================
};

// =============================================================================
// Tests
// =============================================================================

// Tests live in `cx_tests.zig` — see the `comptime _ = @import(...)`
// block near the top of this file for the discovery hook.
