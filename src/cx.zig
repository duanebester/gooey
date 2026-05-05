//! `Cx` — the unified rendering context.
//!
//! `Cx` is the single entry point that render functions and components
//! receive each frame. It groups:
//!
//!   * State access — `cx.state(AppState)` / `cx.stateConst(AppState)`.
//!   * Rendering    — `cx.render(ui.box(...))`.
//!   * Handlers     — `cx.update`, `cx.updateWith`, `cx.command`,
//!                    `cx.commandWith`, `cx.onSelect`, `cx.defer`.
//!   * Sub-namespaces (PR 5): `cx.lists`, `cx.animations`,
//!                    `cx.entities`, `cx.focus`.
//!
//! Handler signatures, in order of "purity":
//!
//!   | API                          | Method shape                |
//!   | ---------------------------- | --------------------------- |
//!   | `cx.update(M)`               | `fn(*State) void`           |
//!   | `cx.updateWith(arg, M)`      | `fn(*State, Arg) void`      |
//!   | `cx.command(M)`              | `fn(*State, *Window) void`   |
//!   | `cx.commandWith(arg, M)`     | `fn(*State, *Window, A) void`|
//!
//! Examples live in `examples/` and the integration tests under
//! `cx_tests.zig`.

const std = @import("std");

// Pull in the split-out test file so `zig build test` discovers its
// tests through the standard reachability graph. The block runs at
// comptime and produces no runtime cost. PR 5 of the cleanup plan
// moved the pattern tests out of `cx.zig` to keep this file under
// the 800-line budget — see `cx_tests.zig` for the bodies.
comptime {
    _ = @import("cx_tests.zig");
}

// Core imports
const window_mod = @import("context/window.zig");
const Window = window_mod.Window;
const ui_mod = @import("ui/mod.zig");
const Builder = ui_mod.Builder;
const AccessibleConfig = ui_mod.AccessibleConfig;
const a11y = @import("accessibility/accessibility.zig");
const change_tracker_mod = @import("context/change_tracker.zig");
const handler_mod = @import("context/handler.zig");
const entity_mod = @import("context/entity.zig");
const text_field_mod = @import("widgets/text_input_state.zig");
const text_area_mod = @import("widgets/text_area_state.zig");
const code_editor_mod = @import("widgets/code_editor_state.zig");
const scroll_view_mod = @import("widgets/scroll_container.zig");
const uniform_list_mod = @import("widgets/uniform_list.zig");
const UniformListState = uniform_list_mod.UniformListState;
const UniformListStyle = ui_mod.UniformListStyle;
const virtual_list_mod = @import("widgets/virtual_list.zig");
const VirtualListState = virtual_list_mod.VirtualListState;
const VirtualListStyle = ui_mod.VirtualListStyle;
const data_table_mod = @import("widgets/data_table.zig");
const DataTableState = data_table_mod.DataTableState;
const DataTableStyle = ui_mod.DataTableStyle;
const ColRange = data_table_mod.ColRange;
const tree_list_mod = @import("widgets/tree_list.zig");
const TreeListState = tree_list_mod.TreeListState;
const TreeEntry = tree_list_mod.TreeEntry;
const TreeListStyle = ui_mod.TreeListStyle;

// PR 8.2 — `SelectState` lives next to the widget in
// `components/select.zig` now (was a `WidgetStore` field pre-PR-8.2).
// `cx.onSelect`'s `forIndexAndClose` path needs the type so it can
// route the close-on-pick through `Window.element_states.get`. The
// import is local to `cx.zig` only — future cleanup of `cx.zig`'s
// per-widget knowledge is tracked separately and not in scope for
// PR 8.2.
const select_mod = @import("components/select.zig");
const SelectState = select_mod.SelectState;

// Text measurement types
const text_mod = @import("text/mod.zig");
pub const TextMeasurement = text_mod.TextMeasurement;

// Animation types (re-exported from root.zig for users)
const animation_mod = @import("animation/mod.zig");
const Animation = animation_mod.AnimationConfig;
const AnimationHandle = animation_mod.AnimationHandle;

// Spring types
const spring_mod = @import("animation/spring.zig");
const SpringConfig = spring_mod.SpringConfig;
const SpringHandle = spring_mod.SpringHandle;

// Stagger types
const stagger_mod = @import("animation/stagger.zig");
const StaggerConfig = stagger_mod.StaggerConfig;

// Motion types
const motion_mod = @import("animation/motion.zig");
const MotionConfig = motion_mod.MotionConfig;
const MotionHandle = motion_mod.MotionHandle;
const SpringMotionConfig = motion_mod.SpringMotionConfig;

// Handler types (re-exported from root.zig for users)
const HandlerRef = handler_mod.HandlerRef;
const OnSelectHandler = handler_mod.OnSelectHandler;
pub const typeId = handler_mod.typeId;
const packArg = handler_mod.packArg;
const unpackArg = handler_mod.unpackArg;

// Entity types (re-exported from root.zig for users)
const EntityId = entity_mod.EntityId;
const Entity = entity_mod.Entity;
const EntityMap = entity_mod.EntityMap;
const EntityContext = entity_mod.EntityContext;

// UI types (re-exported from root.zig for users)
const Theme = ui_mod.Theme;

// Sub-namespace modules (PR 5). Each exposes a zero-sized struct
// that lives as a field on `Cx`; methods on those structs recover
// `*Cx` via `@fieldParentPtr`, giving the `cx.lists.uniform(...)` /
// `cx.animations.spring(...)` call shape without extra storage
// (CLAUDE.md §10 — don't take aliases) and without extra parens.
const lists_mod = @import("cx/lists.zig");
const animations_mod = @import("cx/animations.zig");
const entities_mod = @import("cx/entities.zig");
const focus_mod = @import("cx/focus.zig");

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

    // Sub-namespaces (PR 5). Zero-sized fields default-initialised so
    // existing call-site struct literals (e.g. in `runtime/window_context.zig`)
    // keep compiling untouched. `animations` is plural to avoid
    // colliding with the deprecated `cx.animate(...)` method (PR 9
    // removes the forwarder and frees up the singular name).
    lists: lists_mod.Lists = .{},
    animations: animations_mod.Animations = .{},
    entities: entities_mod.Entities = .{},
    focus: focus_mod.Focus = .{},

    const Self = @This();

    // =========================================================================
    // State Access
    // =========================================================================

    /// Mutable access to the application state. The type must match
    /// the one passed to `runCx`; the assertion enforces that.
    pub fn state(self: *Self, comptime T: type) *T {
        std.debug.assert(self.state_type_id == typeId(T));
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
    pub fn setTitle(self: *Self, title: [:0]const u8) void {
        self._window.window.setTitle(title);
    }

    /// Change the font at runtime. Clears glyph / shape caches and
    /// triggers a re-render.
    pub fn setFont(self: *Self, name: []const u8, size: f32) !void {
        try self._window.setFont(name, size);
    }

    /// Set the glass / blur effect style for the window. No-op on
    /// platforms without native glass support (currently: web).
    pub fn setGlassStyle(
        self: *Self,
        style: anytype,
        opacity: f64,
        corner_radius: f64,
    ) void {
        const platform = @import("platform/mod.zig");

        if (comptime platform.is_wasm) {
            // No-op on web - glass effects not supported
        } else {
            // PR 7b.1b — `_gooey.window` was the optional `*PlatformWindow`
            // field; renamed to `_window.platform_window`. Capture name
            // disambiguated from the new `pub fn window(self: *Self)`
            // accessor on `Cx` (which `cx.window()` callers use).
            const mac_window_mod = platform.mac.window;
            if (self._window.platform_window) |pw| {
                const mac_win: *mac_window_mod.Window = @ptrCast(@alignCast(pw));
                mac_win.setGlassStyle(@enumFromInt(@intFromEnum(style)), opacity, corner_radius);
            }
        }
    }

    /// Close the window (and exit the application). No-op on web —
    /// browser tabs can't be closed programmatically.
    pub fn close(self: *Self) void {
        const platform = @import("platform/mod.zig");

        if (comptime platform.is_wasm) {
            // No-op on web - can't close browser tabs
        } else {
            // PR 7b.1b — capture renamed from `window` to `pw` to
            // avoid shadowing the new `pub fn window(self: *Self)`
            // accessor declared on `Cx`. Field also renamed
            // (`window → platform_window`) on the framework wrapper.
            if (self._window.platform_window) |pw| {
                pw.close();
            }
        }
    }

    /// Quit the application immediately. No-op on web.
    pub fn quit(self: *Self) void {
        self._window.quit();
    }

    // =========================================================================
    // Pure state handlers — `update` / `updateWith`
    // =========================================================================

    /// Handler from a pure state method `fn(*State) void`. The State
    /// type is inferred from the method's first parameter; the UI
    /// re-renders after the method returns.
    pub fn update(
        self: *Self,
        comptime method: anytype,
    ) HandlerRef {
        _ = self;
        const State = comptime ExtractState("update", @TypeOf(method));

        const Wrapper = struct {
            fn invoke(g: *Window, _: EntityId) void {
                const state_ptr = g.getRootState(State) orelse return;
                method(state_ptr);
                g.requestRender();
            }
        };

        return .{
            .callback = Wrapper.invoke,
            .entity_id = EntityId.invalid,
        };
    }

    /// Handler from `fn(*State, Arg) void`. `arg` is captured at
    /// handler-creation time and must fit in 8 bytes (use a pointer
    /// or index for larger payloads — the comptime check enforces it).
    pub fn updateWith(
        self: *Self,
        arg: anytype,
        comptime method: anytype,
    ) HandlerRef {
        _ = self;
        const State = comptime ExtractState("updateWith", @TypeOf(method));
        const Arg = @TypeOf(arg);

        comptime {
            if (@sizeOf(Arg) > @sizeOf(u64)) {
                @compileError("updateWith: argument type '" ++ @typeName(Arg) ++ "' exceeds 8 bytes. Use a pointer or index instead.");
            }
        }

        const packed_entity_id = packArg(Arg, arg);

        const Wrapper = struct {
            fn invoke(g: *Window, packed_arg: EntityId) void {
                const state_ptr = g.getRootState(State) orelse return;
                const unpacked = unpackArg(Arg, packed_arg);
                method(state_ptr, unpacked);
                g.requestRender();
            }
        };

        return .{
            .callback = Wrapper.invoke,
            .entity_id = packed_entity_id,
        };
    }

    // =========================================================================
    // Index-based select handler — `onSelect`
    // =========================================================================

    /// Index-based selection handler from `fn(*State, usize) void`.
    /// Used by `Select`, `TabBar`, etc — the widget generates
    /// per-option `HandlerRef`s internally so callers don't have to
    /// build a handler array. With `Select`, the widget also manages
    /// its own open/close state.
    pub fn onSelect(
        self: *Self,
        comptime method: anytype,
    ) OnSelectHandler {
        _ = self;
        const State = comptime ExtractState("onSelect", @TypeOf(method));

        const Wrapper = struct {
            // EntityId packing:
            //   * upper 32 != 0: lower 32 = index, upper 32 = select
            //     id hash (forIndexAndClose path — also closes internal state)
            //   * upper 32 == 0: full u64 = usize index (forIndex
            //     path — caller manages open/close)
            fn invoke(g: *Window, packed_arg: EntityId) void {
                const id_hash = OnSelectHandler.unpackIdHash(packed_arg);

                if (id_hash != 0) {
                    // forIndexAndClose path: index in lower 32 bits
                    const index: usize = @as(usize, OnSelectHandler.unpackIndex(packed_arg));
                    const state_ptr = g.getRootState(State) orelse return;
                    method(state_ptr, index);

                    // Close internal select state. PR 8.2 — routed
                    // through `Window.element_states.get` (was
                    // `g.widgets.closeSelectState(id_hash)`
                    // pre-PR-8.2). Reaching `forIndexAndClose`
                    // implies the option button just rendered, so
                    // the slot must already exist; the `null` arm
                    // is defensive only.
                    if (g.element_states.get(SelectState, @as(u64, id_hash))) |ss| {
                        ss.is_open = false;
                    }
                } else {
                    // forIndex path: full usize index
                    const index = unpackArg(usize, packed_arg);
                    const state_ptr = g.getRootState(State) orelse return;
                    method(state_ptr, index);
                }

                g.requestRender();
            }
        };

        return .{ .callback = Wrapper.invoke };
    }

    // =========================================================================
    // Command handlers — `command` / `commandWith`
    // =========================================================================

    /// Handler from `fn(*State, *Window) void`. Use when the method
    /// needs framework access — focus, window ops, entity churn.
    pub fn command(
        self: *Self,
        comptime method: anytype,
    ) HandlerRef {
        _ = self;
        const State = comptime ExtractState("command", @TypeOf(method));

        const Wrapper = struct {
            fn invoke(g: *Window, _: EntityId) void {
                const state_ptr = g.getRootState(State) orelse return;
                method(state_ptr, g);
                g.requestRender();
            }
        };

        return .{
            .callback = Wrapper.invoke,
            .entity_id = EntityId.invalid,
        };
    }

    /// Handler from `fn(*State, *Window, Arg) void`. `arg` follows the
    /// same 8-byte capture rule as `updateWith`.
    pub fn commandWith(
        self: *Self,
        arg: anytype,
        comptime method: anytype,
    ) HandlerRef {
        _ = self;
        const State = comptime ExtractState("commandWith", @TypeOf(method));
        const Arg = @TypeOf(arg);

        comptime {
            if (@sizeOf(Arg) > @sizeOf(u64)) {
                @compileError("commandWith: argument type '" ++ @typeName(Arg) ++ "' exceeds 8 bytes. Use a pointer or index instead.");
            }
        }

        const packed_entity_id = packArg(Arg, arg);

        const Wrapper = struct {
            fn invoke(g: *Window, packed_arg: EntityId) void {
                const state_ptr = g.getRootState(State) orelse return;
                const unpacked = unpackArg(Arg, packed_arg);
                method(state_ptr, g, unpacked);
                g.requestRender();
            }
        };

        return .{
            .callback = Wrapper.invoke,
            .entity_id = packed_entity_id,
        };
    }

    // =========================================================================
    // Deferred commands — `defer` / `deferWith`
    // =========================================================================

    /// Schedule `fn(*State, *Window) void` to run after current event
    /// handling completes. Use for modal dialogs and other operations
    /// that can't safely run mid-event (re-entrancy, heavy work).
    pub fn @"defer"(
        self: *Self,
        comptime method: anytype,
    ) void {
        self._window.deferCommand(method);
    }

    /// Schedule `fn(*State, *Window, Arg) void` for after-event
    /// execution. `arg` follows the 8-byte capture rule.
    pub fn deferWith(
        self: *Self,
        arg: anytype,
        comptime method: anytype,
    ) void {
        self._window.deferCommandWith(arg, method);
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
    /// wrapping" / "current font size" respectively.
    pub const MeasureTextOptions = struct {
        max_width: ?f32 = null,
        font_size: ?f32 = null,
    };

    /// Measure a text string with optional wrapping and font size.
    /// Uses the platform text shaper (CoreText / HarfBuzz / browser)
    /// so kerning and wrapping match rendered output.
    pub fn measureText(self: *Self, text_content: []const u8, opts: MeasureTextOptions) !TextMeasurement {
        std.debug.assert(opts.font_size == null or opts.font_size.? > 0);
        std.debug.assert(opts.max_width == null or opts.max_width.? > 0);

        const ts = self._window.getTextSystem();

        if (opts.font_size) |requested_size| {
            const metrics = ts.getMetrics() orelse return error.NoFontLoaded;
            std.debug.assert(metrics.point_size > 0);
            const scale = requested_size / metrics.point_size;
            std.debug.assert(scale > 0);

            // Scale max_width into base-font units so wrapping breaks at
            // the correct character positions, then scale the result back.
            const base_max_width: ?f32 = if (opts.max_width) |mw| mw / scale else null;
            var m = try ts.measureTextEx(text_content, base_max_width);
            m.width *= scale;
            m.height *= scale;
            return m;
        }

        return ts.measureTextEx(text_content, opts.max_width);
    }

    // =========================================================================
    // Entities (deprecated forwarders — see `cx/entities.zig`; PR 9 removes)
    // =========================================================================
    pub fn createEntity(self: *Self, comptime T: type, value: T) !Entity(T) {
        return self.entities.create(T, value);
    }
    pub fn readEntity(self: *Self, comptime T: type, entity: Entity(T)) ?*const T {
        return self.entities.read(T, entity);
    }
    pub fn writeEntity(self: *Self, comptime T: type, entity: Entity(T)) ?*T {
        return self.entities.write(T, entity);
    }
    pub fn entityCx(self: *Self, comptime T: type, entity: Entity(T)) ?EntityContext(T) {
        return self.entities.context(T, entity);
    }

    /// Request a UI re-render.
    pub fn notify(self: *Self) void {
        self._window.requestRender();
    }

    // =========================================================================
    // Focus (deprecated forwarders — see `cx/focus.zig`; removed in PR 9)
    // =========================================================================

    // Deprecated: use `cx.focus.*` instead. The text-field /
    // text-area distinction collapsed in PR 4 — both routed through
    // `Window.focusWidget` already.
    pub fn focusNext(self: *Self) void {
        self.focus.next();
    }
    pub fn focusPrev(self: *Self) void {
        self.focus.prev();
    }
    pub fn blurAll(self: *Self) void {
        self.focus.blurAll();
    }
    pub fn focusTextField(self: *Self, id: []const u8) void {
        self.focus.widget(id);
    }
    pub fn focusTextArea(self: *Self, id: []const u8) void {
        self.focus.widget(id);
    }
    pub fn isElementFocused(self: *Self, id: []const u8) bool {
        return self.focus.isElementFocused(id);
    }

    // Widget access (for advanced use cases). Each returns `null` if
    // no widget with that id has been registered.
    pub fn textField(self: *Self, id: []const u8) ?*text_field_mod.TextInput {
        return self._window.widgets.textInput(id);
    }
    pub fn textAreaWidget(self: *Self, id: []const u8) ?*text_area_mod.TextArea {
        return self._window.widgets.textArea(id);
    }
    pub fn codeEditorWidget(self: *Self, id: []const u8) ?*code_editor_mod.CodeEditorState {
        return self._window.widgets.codeEditor(id);
    }
    pub fn scrollView(self: *Self, id: []const u8) ?*scroll_view_mod.ScrollContainer {
        return self._window.widgets.scrollContainer(id);
    }

    /// Render an element tree. Works with any renderable — `ui.*`
    /// primitives, layout containers, components whose `render`
    /// accepts `*Cx` *or* `*ui.Builder`. Auto-dispatch picks the right
    /// signature so callers don't reach for the builder manually.
    pub fn render(self: *Self, element: anytype) void {
        self._builder.processChildren(element);
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
    // Animations (deprecated forwarders — see `cx/animations.zig`; PR 9 removes)
    // =========================================================================

    pub fn animateComptime(self: *Self, comptime id: []const u8, config: Animation) AnimationHandle {
        return self.animations.tweenComptime(id, config);
    }
    pub fn animate(self: *Self, id: []const u8, config: Animation) AnimationHandle {
        return self.animations.tween(id, config);
    }
    pub fn restartAnimationComptime(self: *Self, comptime id: []const u8, config: Animation) AnimationHandle {
        return self.animations.restartComptime(id, config);
    }
    pub fn restartAnimation(self: *Self, id: []const u8, config: Animation) AnimationHandle {
        return self.animations.restart(id, config);
    }
    pub fn animateOnComptime(self: *Self, comptime id: []const u8, trigger: anytype, config: Animation) AnimationHandle {
        return self.animations.tweenOnComptime(id, trigger, config);
    }
    pub fn animateOn(self: *Self, id: []const u8, trigger: anytype, config: Animation) AnimationHandle {
        return self.animations.tweenOn(id, trigger, config);
    }
    pub fn springComptime(self: *Self, comptime id: []const u8, config: SpringConfig) SpringHandle {
        return self.animations.springComptime(id, config);
    }
    pub fn spring(self: *Self, id: []const u8, config: SpringConfig) SpringHandle {
        return self.animations.spring(id, config);
    }
    pub fn staggerComptime(self: *Self, comptime id: []const u8, index: u32, total_count: u32, config: StaggerConfig) AnimationHandle {
        return self.animations.staggerComptime(id, index, total_count, config);
    }
    pub fn stagger(self: *Self, id: []const u8, index: u32, total_count: u32, config: StaggerConfig) AnimationHandle {
        return self.animations.stagger(id, index, total_count, config);
    }
    pub fn motionComptime(self: *Self, comptime id: []const u8, show: bool, config: MotionConfig) MotionHandle {
        return self.animations.motionComptime(id, show, config);
    }
    pub fn motion(self: *Self, id: []const u8, show: bool, config: MotionConfig) MotionHandle {
        return self.animations.motion(id, show, config);
    }
    pub fn springMotionComptime(self: *Self, comptime id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
        return self.animations.springMotionComptime(id, show, config);
    }
    pub fn springMotion(self: *Self, id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
        return self.animations.springMotion(id, show, config);
    }

    // =========================================================================
    // Change detection
    // =========================================================================

    /// True when the value at `key` differs from the previous frame.
    /// First call for a key returns false — there's no prior value to
    /// diff against. Replaces the module-level `var last_foo` /
    /// manual-diff pattern. Works with any value type; pointer types
    /// compare by address (identity), not pointee.
    pub fn changed(self: *Self, comptime key: []const u8, value: anytype) bool {
        const key_hash = comptime animation_mod.hashString(key);
        const value_hash = change_tracker_mod.hashValue(@TypeOf(value), value);
        return self._window.widgets.change_tracker.changed(key_hash, value_hash);
    }

    // =========================================================================
    // Lists / tables (deprecated forwarders — see `cx/lists.zig`; PR 9 removes)
    // =========================================================================

    pub fn uniformList(
        self: *Self,
        id: []const u8,
        list_state: *UniformListState,
        style: UniformListStyle,
        comptime render_item: fn (index: u32, cx: *Self) void,
    ) void {
        self.lists.uniform(id, list_state, style, render_item);
    }

    pub fn treeList(
        self: *Self,
        id: []const u8,
        tree_state: *TreeListState,
        style: TreeListStyle,
        comptime render_item: fn (entry: *const TreeEntry, cx: *Self) void,
    ) void {
        self.lists.tree(id, tree_state, style, render_item);
    }

    pub fn virtualList(
        self: *Self,
        id: []const u8,
        list_state: *VirtualListState,
        style: VirtualListStyle,
        comptime render_item: fn (index: u32, cx: *Self) f32,
    ) void {
        self.lists.virtual(id, list_state, style, render_item);
    }

    /// Deprecated alias: same type as `cx.lists.DataTableCallbacks(Cx)`.
    pub fn DataTableCallbacks(comptime CxType: type) type {
        return lists_mod.Lists.DataTableCallbacks(CxType);
    }

    pub fn dataTable(
        self: *Self,
        id: []const u8,
        table_state: *DataTableState,
        style: DataTableStyle,
        comptime callbacks: DataTableCallbacks(Self),
    ) void {
        self.lists.dataTable(id, table_state, style, callbacks);
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Extract the State type from a handler method's first parameter.
///
/// All handler methods follow the pattern `fn(*State, ...) void` where the
/// first parameter is always a pointer to the state type. This helper uses
/// `@typeInfo` to pull the pointee type from that first parameter, eliminating
/// the need to pass the State type explicitly.
///
/// Produces clear compile errors if the function signature doesn't match
/// the expected pattern (not a function, no parameters, first param not a pointer).
fn ExtractState(comptime caller: []const u8, comptime Fn: type) type {
    const info = @typeInfo(Fn);
    if (info != .@"fn") {
        @compileError(caller ++ "() expects a function, got " ++ @typeName(Fn));
    }
    const fn_info = info.@"fn";
    if (fn_info.params.len == 0) {
        @compileError(caller ++ "() expects a method with at least one parameter (*State), got a function with no parameters");
    }
    const FirstParam = fn_info.params[0].type orelse {
        @compileError(caller ++ "() expects a concrete first parameter type (*State), got anytype");
    };
    const ptr_info = @typeInfo(FirstParam);
    if (ptr_info != .pointer or ptr_info.pointer.size != .one) {
        @compileError(caller ++ "() expects first parameter to be *State (single-item pointer), got " ++ @typeName(FirstParam));
    }
    return ptr_info.pointer.child;
}

// `computeTriggerHash` used to live here; it now lives next to the
// `tweenOn` / `tweenOnComptime` callers in `cx/animations.zig`. The
// deprecated forwarders on `Cx` route through that copy, so a single
// implementation drives both call paths.

// =============================================================================
// Tests
// =============================================================================

// Tests live in `cx_tests.zig` — see the `comptime _ = @import(...)`
// block near the top of this file for the discovery hook. PR 5 moved
// them out so this file could shed ~420 lines.
