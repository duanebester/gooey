//! Cx - The Unified Rendering Context
//!
//! Provides access to:
//! - Rendering via `cx.render()` with `ui.*` elements
//! - Application state
//! - Window operations
//! - Entity system
//! - Focus management
//!
//! ## Rendering Pattern
//!
//! Use `cx.render()` with UI primitives from `gooey.ui`:
//!
//! ```zig
//! const ui = gooey.ui;
//!
//! fn render(cx: *gooey.Cx) void {
//!     const s = cx.state(AppState);
//!
//!     cx.render(ui.vstack(.{ .gap = 8 }, .{
//!         ui.text("Hello", .{}),
//!         ui.hstack(.{ .gap = 4 }, .{
//!             ui.text("Count: ", .{}),
//!             ui.textFmt("{}", .{s.count}, .{}),
//!         }),
//!     }));
//! }
//! ```
//!
//! ## Handler Types
//!
//! | API | Signature | Use Case |
//! |-----|-----------|----------|
//! | `cx.update(State, fn)` | `fn(*State) void` | Pure state mutation |
//! | `cx.updateWith(State, arg, fn)` | `fn(*State, Arg) void` | Pure with data |
//! | `cx.command(State, fn)` | `fn(*State, *Gooey) void` | Framework ops |
//! | `cx.commandWith(State, arg, fn)` | `fn(*State, *Gooey, Arg) void` | Framework ops + data |
//!
//! ## Example
//!
//! ```zig
//! const gooey = @import("gooey");
//! const ui = gooey.ui;
//!
//! const AppState = struct {
//!     count: i32 = 0,
//!
//!     pub fn increment(self: *AppState) void {
//!         self.count += 1;
//!     }
//!
//!     pub fn setCount(self: *AppState, value: i32) void {
//!         self.count = value;
//!     }
//! };
//!
//! fn render(cx: *gooey.Cx) void {
//!     const s = cx.state(AppState);
//!     const size = cx.windowSize();
//!
//!     cx.render(ui.box(.{
//!         .width = size.width,
//!         .height = size.height,
//!     }, .{
//!         ui.textFmt("Count: {}", .{s.count}, .{}),
//!         gooey.Button{ .label = "+", .on_click_handler = cx.update(AppState, AppState.increment) },
//!         gooey.Button{ .label = "Reset", .on_click_handler = cx.updateWith(AppState, @as(i32, 0), AppState.setCount) },
//!     }));
//! }
//! ```

const std = @import("std");

// Core imports
const gooey_mod = @import("context/gooey.zig");
const Gooey = gooey_mod.Gooey;
const ui_mod = @import("ui/mod.zig");
const Builder = ui_mod.Builder;
const AccessibleConfig = ui_mod.AccessibleConfig;
const a11y = @import("accessibility/accessibility.zig");
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

/// Cx - The unified rendering context
///
/// Provides a single entry point for:
/// - State access: `cx.state(AppState)`
/// - Rendering: `cx.render(ui.box(...))`, `cx.render(ui.vstack(...))`
/// - Handler creation: `cx.update()`, `cx.command()`, etc.
/// - Entity operations: `cx.createEntity()`, `cx.entityCx()`, etc.
/// - Window operations: `cx.windowSize()`, `cx.scaleFactor()`, etc.
/// - Focus management: `cx.focusNext()`, `cx.blurAll()`, etc.
pub const Cx = struct {
    _allocator: std.mem.Allocator,

    /// Internal runtime coordinator (manages scene, layout, widgets, etc.)
    _gooey: *Gooey,

    /// Layout builder
    _builder: *Builder,

    /// Type-erased state pointer (set at app init)
    state_ptr: *anyopaque,

    /// Type ID for runtime type checking
    state_type_id: usize,

    /// Internal ID counter for generated IDs
    id_counter: u32 = 0,

    const Self = @This();

    // =========================================================================
    // State Access
    // =========================================================================

    /// Get mutable access to the application state.
    ///
    /// The type must match the state type passed to `runCx`.
    pub fn state(self: *Self, comptime T: type) *T {
        std.debug.assert(self.state_type_id == typeId(T));
        return @ptrCast(@alignCast(self.state_ptr));
    }

    /// Get read-only access to the application state.
    pub fn stateConst(self: *Self, comptime T: type) *const T {
        return self.state(T);
    }

    // =========================================================================
    // Window Operations
    // =========================================================================

    /// Get the current window size in logical pixels.
    pub fn windowSize(self: *Self) struct { width: f32, height: f32 } {
        return .{
            .width = self._gooey.width,
            .height = self._gooey.height,
        };
    }

    /// Get the display scale factor (e.g., 2.0 for Retina).
    pub fn scaleFactor(self: *Self) f32 {
        return self._gooey.scale_factor;
    }

    /// Set the window title.
    pub fn setTitle(self: *Self, title: [:0]const u8) void {
        self._gooey.window.setTitle(title);
    }

    /// Change the font at runtime.
    /// Clears glyph and shape caches and triggers a re-render.
    ///
    /// Example:
    /// ```
    /// cx.setFont("JetBrains Mono", 14.0);
    /// ```
    pub fn setFont(self: *Self, name: []const u8, size: f32) !void {
        try self._gooey.setFont(name, size);
    }

    /// Set the glass/blur effect style for the window.
    /// Only has an effect on platforms that support glass effects (e.g., macOS).
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
            const mac_window = platform.mac.window;
            const window: *mac_window.Window = @ptrCast(@alignCast(self._gooey.window.ptr));
            window.setGlassStyle(@enumFromInt(@intFromEnum(style)), opacity, corner_radius);
        }
    }

    /// Close the window (and exit the application).
    /// On web platforms, this is a no-op since browser tabs can't be closed programmatically.
    pub fn close(self: *Self) void {
        const platform = @import("platform/mod.zig");

        if (comptime platform.is_wasm) {
            // No-op on web - can't close browser tabs
        } else {
            if (self._gooey.window) |window| {
                window.close();
            }
        }
    }

    /// Quit the application immediately.
    /// On web platforms, this is a no-op since browser tabs can't be closed programmatically.
    pub fn quit(_: *Self) void {
        const platform = @import("platform/mod.zig");

        if (comptime platform.is_wasm) {
            // No-op on web - can't quit browser
        } else if (comptime platform.is_linux) {
            // Linux: need to access platform to quit
            // For now, just exit
            std.process.exit(0);
        } else {
            // macOS: call NSApp terminate:
            const objc = @import("objc");
            const NSApp = objc.getClass("NSApplication") orelse return;
            const app = NSApp.msgSend(objc.Object, "sharedApplication", .{});
            app.msgSend(void, "terminate:", .{@as(?*anyopaque, null)});
        }
    }

    // =========================================================================
    // Pure State Handlers - update / updateWith
    // =========================================================================

    /// Create a handler from a pure state method.
    ///
    /// The method should be `fn(*State) void` - no context parameter.
    /// After the method is called, the UI automatically re-renders.
    pub fn update(
        self: *Self,
        comptime State: type,
        comptime method: fn (*State) void,
    ) HandlerRef {
        _ = self;

        const Wrapper = struct {
            fn invoke(g: *Gooey, _: EntityId) void {
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

    /// Create a handler from a pure state method that takes an argument.
    ///
    /// The method should be `fn(*State, ArgType) void`.
    /// The argument is captured and passed when the handler is invoked.
    ///
    /// **Note:** The argument must fit in 8 bytes (u64).
    pub fn updateWith(
        self: *Self,
        comptime State: type,
        arg: anytype,
        comptime method: fn (*State, @TypeOf(arg)) void,
    ) HandlerRef {
        _ = self;
        const Arg = @TypeOf(arg);

        comptime {
            if (@sizeOf(Arg) > @sizeOf(u64)) {
                @compileError("updateWith: argument type '" ++ @typeName(Arg) ++ "' exceeds 8 bytes. Use a pointer or index instead.");
            }
        }

        const packed_entity_id = packArg(Arg, arg);

        const Wrapper = struct {
            fn invoke(g: *Gooey, packed_arg: EntityId) void {
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
    // Command Handlers - command / commandWith (Framework Access)
    // =========================================================================

    /// Create a command handler that has framework access.
    ///
    /// The method should be `fn(*State, *Gooey) void`.
    /// Use this when you need to perform framework operations like:
    /// - Focus management (`g.focusTextInput()`, `g.blurAll()`)
    /// - Window operations
    /// - Entity creation/removal
    pub fn command(
        self: *Self,
        comptime State: type,
        comptime method: fn (*State, *Gooey) void,
    ) HandlerRef {
        _ = self;

        const Wrapper = struct {
            fn invoke(g: *Gooey, _: EntityId) void {
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

    /// Create a command handler with an argument that has framework access.
    ///
    /// The method should be `fn(*State, *Gooey, ArgType) void`.
    ///
    /// **Note:** The argument must fit in 8 bytes (u64).
    pub fn commandWith(
        self: *Self,
        comptime State: type,
        arg: anytype,
        comptime method: fn (*State, *Gooey, @TypeOf(arg)) void,
    ) HandlerRef {
        _ = self;
        const Arg = @TypeOf(arg);

        comptime {
            if (@sizeOf(Arg) > @sizeOf(u64)) {
                @compileError("commandWith: argument type '" ++ @typeName(Arg) ++ "' exceeds 8 bytes. Use a pointer or index instead.");
            }
        }

        const packed_entity_id = packArg(Arg, arg);

        const Wrapper = struct {
            fn invoke(g: *Gooey, packed_arg: EntityId) void {
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
    // Deferred Commands - defer / deferWith
    // =========================================================================

    /// Schedule a state method to run after current event handling completes.
    /// Useful for opening dialogs, avoiding re-entrancy, or deferring heavy work.
    ///
    /// The method signature is `fn(*State, *Gooey) void` - same as `command()`.
    ///
    /// Example:
    /// ```
    /// pub fn openFolder(self: *State, g: *Gooey) void {
    ///     // Can't open modal dialog mid-event - defer it
    ///     g.defer(State, State.openFolderDeferred);
    /// }
    ///
    /// pub fn openFolderDeferred(self: *State, g: *Gooey) void {
    ///     // Safe to open modal dialog here
    ///     if (file_dialog.chooseFolder()) |path| {
    ///         self.loadDirectory(path);
    ///     }
    /// }
    /// ```
    pub fn @"defer"(
        self: *Self,
        comptime State: type,
        comptime method: fn (*State, *Gooey) void,
    ) void {
        self._gooey.deferCommand(State, method);
    }

    /// Schedule a state method with an argument to run after current event handling completes.
    ///
    /// The method signature is `fn(*State, *Gooey, ArgType) void`.
    /// The argument must fit in 8 bytes (use a pointer or index for larger data).
    ///
    /// Example:
    /// ```
    /// pub fn openFile(self: *State, index: u32) void {
    ///     // Defer the actual file opening
    ///     g.deferWith(State, index, State.openFileDeferred);
    /// }
    ///
    /// pub fn openFileDeferred(self: *State, g: *Gooey, index: u32) void {
    ///     const path = self.files[index].path;
    ///     // Open file dialog or load file...
    /// }
    /// ```
    pub fn deferWith(
        self: *Self,
        comptime State: type,
        arg: anytype,
        comptime method: fn (*State, *Gooey, @TypeOf(arg)) void,
    ) void {
        self._gooey.deferCommandWith(State, @TypeOf(arg), arg, method);
    }

    // =========================================================================
    // Entity Operations
    // =========================================================================

    /// Create a new entity with the given initial value.
    pub fn createEntity(self: *Self, comptime T: type, value: T) !Entity(T) {
        return self._gooey.entities.new(T, value);
    }

    /// Read an entity's data (immutable).
    pub fn readEntity(self: *Self, comptime T: type, entity: Entity(T)) ?*const T {
        return self._gooey.readEntity(T, entity);
    }

    /// Write to an entity's data (mutable).
    pub fn writeEntity(self: *Self, comptime T: type, entity: Entity(T)) ?*T {
        return self._gooey.writeEntity(T, entity);
    }

    /// Get an entity-scoped context for handlers.
    ///
    /// Returns null if the entity doesn't exist.
    pub fn entityCx(self: *Self, comptime T: type, entity: Entity(T)) ?EntityContext(T) {
        if (!self._gooey.entities.exists(entity.id)) return null;
        return EntityContext(T){
            .gooey = self._gooey,
            .entities = &self._gooey.entities,
            .entity_id = entity.id,
        };
    }

    // =========================================================================
    // Render Lifecycle
    // =========================================================================

    /// Request a UI re-render.
    pub fn notify(self: *Self) void {
        self._gooey.requestRender();
    }

    // =========================================================================
    // Focus Management
    // =========================================================================

    /// Move focus to the next focusable element.
    pub fn focusNext(self: *Self) void {
        self._gooey.focusNext();
    }

    /// Move focus to the previous focusable element.
    pub fn focusPrev(self: *Self) void {
        self._gooey.focusPrev();
    }

    /// Remove focus from all elements.
    pub fn blurAll(self: *Self) void {
        self._gooey.blurAll();
    }

    /// Focus a specific text field by ID.
    pub fn focusTextField(self: *Self, id: []const u8) void {
        self._gooey.focusTextInput(id);
    }

    /// Focus a specific text area by ID.
    pub fn focusTextArea(self: *Self, id: []const u8) void {
        self._gooey.focusTextArea(id);
    }

    /// Check if a specific element is focused.
    pub fn isElementFocused(self: *Self, id: []const u8) bool {
        return self._gooey.isElementFocused(id);
    }

    // =========================================================================
    // Widget Access (for advanced use cases)
    // =========================================================================

    /// Get a text field widget by ID.
    pub fn textField(self: *Self, id: []const u8) ?*text_field_mod.TextInput {
        return self._gooey.textInput(id);
    }

    /// Get a text area widget by ID.
    pub fn textAreaWidget(self: *Self, id: []const u8) ?*text_area_mod.TextArea {
        return self._gooey.textArea(id);
    }

    /// Get a code editor widget by ID.
    pub fn codeEditorWidget(self: *Self, id: []const u8) ?*code_editor_mod.CodeEditorState {
        return self._gooey.codeEditor(id);
    }

    /// Get a scroll view widget by ID.
    pub fn scrollView(self: *Self, id: []const u8) ?*scroll_view_mod.ScrollContainer {
        return self._gooey.widgets.scrollContainer(id);
    }

    // =========================================================================
    // Layout Building - Delegates to Builder
    // =========================================================================

    /// Render an element tree. This is the primary entry point for the new ui.* API.
    ///
    /// Usage:
    /// ```
    /// cx.render(ui.box(.{ .background = t.bg }, .{
    ///     ui.text("Hello", .{}),
    ///     ui.hstack(.{ .gap = 8 }, .{
    ///         ui.text("A", .{}),
    ///         ui.text("B", .{}),
    ///     }),
    /// }));
    /// ```
    pub fn render(self: *Self, element: anytype) void {
        self._builder.processChildren(element);
    }

    // =========================================================================
    // Accessibility API
    // =========================================================================

    /// Begin an accessible element. Call before the visual element.
    /// Returns true if a11y is active and element was pushed.
    /// Must be paired with accessibleEnd() when returns true.
    ///
    /// ## Example
    /// ```zig
    /// const a11y_pushed = cx.accessible(.{ .role = .button, .name = "Submit" });
    /// defer if (a11y_pushed) cx.accessibleEnd();
    /// // ... render visual element ...
    /// ```
    pub fn accessible(self: *Self, config: AccessibleConfig) bool {
        return self._builder.accessible(config);
    }

    /// End current accessible element.
    /// Must be called after accessible() returns true.
    pub fn accessibleEnd(self: *Self) void {
        self._builder.accessibleEnd();
    }

    /// Announce a message to screen readers.
    /// Use .polite for non-urgent updates, .assertive for critical alerts.
    ///
    /// ## Example
    /// ```zig
    /// cx.announce("Item deleted", .polite);
    /// cx.announce("Error: connection lost", .assertive);
    /// ```
    pub fn announce(self: *Self, message: []const u8, priority: a11y.Live) void {
        self._builder.announce(message, priority);
    }

    /// Check if accessibility is currently enabled
    pub fn isA11yEnabled(self: *Self) bool {
        return self._builder.isA11yEnabled();
    }

    // =========================================================================
    // Internal Access (for advanced use cases / migration)
    // =========================================================================

    /// Get the underlying Gooey runtime.
    pub fn gooey(self: *Self) *Gooey {
        return self._gooey;
    }

    /// Get the underlying Builder.
    pub fn builder(self: *Self) *Builder {
        return self._builder;
    }

    /// Get the allocator.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return self._allocator;
    }

    // =========================================================================
    // Theme API
    // =========================================================================

    /// Set the theme for this context and all child components.
    /// Call at the start of render to establish theme context.
    ///
    /// ```zig
    /// fn render(cx: *Cx) void {
    ///     const s = cx.state(AppState);
    ///     cx.setTheme(s.theme);  // Set theme once
    ///     // All children auto-inherit theme colors
    /// }
    /// ```
    pub fn setTheme(self: *Self, theme_ptr: *const Theme) void {
        self._builder.setTheme(theme_ptr);
    }

    /// Get the current theme, falling back to light theme if none set.
    /// Components use this to resolve null color fields.
    pub fn theme(self: *Self) *const Theme {
        return self._builder.theme();
    }

    // =========================================================================
    // Animation API
    // =========================================================================

    /// Animate with compile-time string hashing (most efficient for literals)
    pub fn animateComptime(self: *Self, comptime id: []const u8, config: Animation) AnimationHandle {
        const anim_id = comptime animation_mod.hashString(id);
        return self._gooey.widgets.animateById(anim_id, config);
    }

    /// Runtime string API (for dynamic IDs)
    pub fn animate(self: *Self, id: []const u8, config: Animation) AnimationHandle {
        return self._gooey.widgets.animate(id, config);
    }

    /// Restart with comptime hashing
    pub fn restartAnimationComptime(self: *Self, comptime id: []const u8, config: Animation) AnimationHandle {
        const anim_id = comptime animation_mod.hashString(id);
        return self._gooey.widgets.restartAnimationById(anim_id, config);
    }

    /// Runtime restart API
    pub fn restartAnimation(self: *Self, id: []const u8, config: Animation) AnimationHandle {
        return self._gooey.widgets.restartAnimation(id, config);
    }

    /// animateOn with comptime ID hashing
    pub fn animateOnComptime(
        self: *Self,
        comptime id: []const u8,
        trigger: anytype,
        config: Animation,
    ) AnimationHandle {
        const anim_id = comptime animation_mod.hashString(id);
        const trigger_hash = computeTriggerHash(@TypeOf(trigger), trigger);
        return self._gooey.widgets.animateOnById(anim_id, trigger_hash, config);
    }

    /// Runtime animateOn API
    pub fn animateOn(
        self: *Self,
        id: []const u8,
        trigger: anytype,
        config: Animation,
    ) AnimationHandle {
        const trigger_hash = computeTriggerHash(@TypeOf(trigger), trigger);
        return self._gooey.widgets.animateOn(id, trigger_hash, config);
    }

    // =========================================================================
    // Spring API
    // =========================================================================

    /// Declarative spring animation. Set the target every frame;
    /// the spring smoothly tracks it, inheriting velocity on interruption.
    ///
    /// ```zig
    /// const s = cx.spring("panel-height", .{
    ///     .target = if (expanded) 1.0 else 0.0,
    ///     .stiffness = 200,
    ///     .damping = 20,
    /// });
    /// const height = lerp(0.0, 300.0, s.clamped());
    /// ```
    pub fn springComptime(self: *Self, comptime id: []const u8, config: SpringConfig) SpringHandle {
        const spring_id = comptime animation_mod.hashString(id);
        return self._gooey.widgets.springById(spring_id, config);
    }

    /// Runtime string spring API (for dynamic IDs).
    pub fn spring(self: *Self, id: []const u8, config: SpringConfig) SpringHandle {
        return self._gooey.widgets.spring(id, config);
    }

    // =========================================================================
    // Stagger API
    // =========================================================================

    /// Staggered animation for list items. Each item gets its own animation
    /// with a computed delay based on its index and the stagger direction.
    ///
    /// ```zig
    /// for (items, 0..) |item, i| {
    ///     const anim = cx.stagger("list-enter", @intCast(i), @intCast(items.len), .list);
    ///     cx.render(ui.box(.{
    ///         .background = Color.white.withAlpha(anim.progress),
    ///     }, .{ ui.text(item.name, .{}) }));
    /// }
    /// ```
    pub fn staggerComptime(
        self: *Self,
        comptime id: []const u8,
        index: u32,
        total_count: u32,
        config: StaggerConfig,
    ) AnimationHandle {
        const base_id = comptime animation_mod.hashString(id);
        return self._gooey.widgets.staggerById(base_id, index, total_count, config);
    }

    /// Runtime string stagger API (for dynamic IDs).
    pub fn stagger(
        self: *Self,
        id: []const u8,
        index: u32,
        total_count: u32,
        config: StaggerConfig,
    ) AnimationHandle {
        return self._gooey.widgets.stagger(id, index, total_count, config);
    }

    // =========================================================================
    // Motion API (tween-based)
    // =========================================================================

    /// Tween-based motion container. Manages enter/exit lifecycle.
    ///
    /// ```zig
    /// const m = cx.motion("panel", show_panel, .fade);
    /// if (m.visible) {
    ///     cx.render(ui.box(.{
    ///         .background = Color.blue.withAlpha(m.progress),
    ///     }, .{ /* ... */ }));
    /// }
    /// ```
    pub fn motionComptime(self: *Self, comptime id: []const u8, show: bool, config: MotionConfig) MotionHandle {
        const mid = comptime animation_mod.hashString(id);
        return self._gooey.widgets.motionById(mid, show, config);
    }

    /// Runtime string motion API (for dynamic IDs).
    pub fn motion(self: *Self, id: []const u8, show: bool, config: MotionConfig) MotionHandle {
        return self._gooey.widgets.motion(id, show, config);
    }

    // =========================================================================
    // Spring Motion API
    // =========================================================================

    /// Spring-based motion container. Interruptible enter/exit.
    ///
    /// ```zig
    /// const m = cx.springMotion("modal", show_modal, .bouncy);
    /// if (m.visible) {
    ///     cx.render(ui.box(.{
    ///         .width = lerp(0.0, 400.0, m.progress),
    ///     }, .{ /* ... */ }));
    /// }
    /// ```
    pub fn springMotionComptime(self: *Self, comptime id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
        const mid = comptime animation_mod.hashString(id);
        return self._gooey.widgets.springMotionById(mid, show, config);
    }

    /// Runtime string spring motion API (for dynamic IDs).
    pub fn springMotion(self: *Self, id: []const u8, show: bool, config: SpringMotionConfig) MotionHandle {
        return self._gooey.widgets.springMotion(id, show, config);
    }

    // =========================================================================
    // Uniform List API
    // =========================================================================

    /// Render a virtualized uniform-height list.
    /// The render callback receives *Cx for full access to state and handlers.
    ///
    /// Example:
    /// ```zig
    /// cx.uniformList("my-list", &state.list_state, .{ .grow_height = true }, renderItem);
    ///
    /// fn renderItem(index: u32, cx: *Cx) void {
    ///     const s = cx.stateConst(State);
    ///     cx.render(ui.box(.{
    ///         .height = 32,
    ///         .on_click_handler = cx.updateWith(State, index, State.selectItem),
    ///     }, .{ ui.text(s.items[index].name, .{}) }));
    /// }
    /// ```
    pub fn uniformList(
        self: *Self,
        id: []const u8,
        list_state: *UniformListState,
        style: UniformListStyle,
        comptime render_item: fn (index: u32, cx: *Self) void,
    ) void {
        const b = self._builder;

        // Sync gap and scroll state
        list_state.gap_px = style.gap;
        b.syncUniformListScroll(id, list_state);

        // Compute layout parameters
        const params = Builder.computeUniformListLayout(id, list_state, style);

        // Open viewport and content elements
        const content_id = b.openUniformListElements(params, style, list_state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        b.renderUniformListSpacer(params.top_spacer_height);

        // Render visible items with Cx access
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            render_item(i, self);
        }

        // Bottom spacer (items below visible range)
        b.renderUniformListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        b.layout.closeElement();
        b.layout.closeElement();

        // Register for scroll handling
        b.registerUniformListScroll(id, params, content_id, style);
    }

    // =========================================================================
    // Tree List API
    // =========================================================================

    /// Render a virtualized tree list with expandable/collapsible nodes.
    /// The render callback receives the TreeEntry and *Cx for full access.
    ///
    /// Example:
    /// ```zig
    /// cx.treeList("file-tree", &state.tree_state, .{ .grow_height = true }, renderNode);
    ///
    /// fn renderNode(entry: *const TreeEntry, cx: *Cx) void {
    ///     const s = cx.stateConst(State);
    ///     const indent = @as(f32, @floatFromInt(entry.depth)) * 16;
    ///     cx.render(ui.hstack(.{ .padding = .{ .each = .{ .top = 0, .right = 0, .bottom = 0, .left = indent } } }, .{
    ///         if (entry.is_folder)
    ///             ui.text(if (entry.is_expanded) "▼" else "▶", .{})
    ///         else
    ///             ui.text("  ", .{}),
    ///         ui.text(s.node_names[entry.node_index], .{}),
    ///     }));
    /// }
    /// ```
    pub fn treeList(
        self: *Self,
        id: []const u8,
        tree_state: *TreeListState,
        style: TreeListStyle,
        comptime render_item: fn (entry: *const TreeEntry, cx: *Self) void,
    ) void {
        const b = self._builder;

        // Rebuild flattened entries if needed
        if (tree_state.needs_flatten) {
            tree_state.rebuild();
        }

        // Sync indent from style
        tree_state.indent_px = style.indent_px;

        // Convert TreeListStyle to UniformListStyle for delegation
        const list_style = UniformListStyle{
            .width = style.width,
            .height = style.height,
            .grow = style.grow,
            .grow_width = style.grow_width,
            .grow_height = style.grow_height,
            .fill_width = style.fill_width,
            .fill_height = style.fill_height,
            .padding = style.padding,
            .gap = style.gap,
            .background = style.background,
            .corner_radius = style.corner_radius,
            .scrollbar_size = style.scrollbar_size,
            .track_color = style.track_color,
            .thumb_color = style.thumb_color,
        };

        // Sync gap and scroll state
        tree_state.list_state.gap_px = style.gap;
        b.syncUniformListScroll(id, &tree_state.list_state);

        // Compute layout parameters
        const params = Builder.computeUniformListLayout(id, &tree_state.list_state, list_style);

        // Open viewport and content elements
        const content_id = b.openUniformListElements(params, list_style, tree_state.list_state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        b.renderUniformListSpacer(params.top_spacer_height);

        // Render visible entries with Cx access
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            if (i < tree_state.entry_count) {
                render_item(&tree_state.entries[i], self);
            }
        }

        // Bottom spacer (items below visible range)
        b.renderUniformListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        b.layout.closeElement();
        b.layout.closeElement();

        // Register for scroll handling
        b.registerUniformListScroll(id, params, content_id, list_style);
    }

    // =========================================================================
    // Virtual List API
    // =========================================================================

    /// Render a virtualized variable-height list.
    /// The render callback receives *Cx for full access to state and handlers,
    /// and must return the actual height of the rendered item for caching.
    ///
    /// Example:
    /// ```zig
    /// cx.virtualList("my-list", &state.list_state, .{ .grow_height = true }, renderItem);
    ///
    /// fn renderItem(index: u32, cx: *Cx) f32 {
    ///     const s = cx.stateConst(State);
    ///     const item = s.items[index];
    ///     const height: f32 = if (item.expanded) 100.0 else 40.0;
    ///     cx.render(ui.box(.{
    ///         .height = height,
    ///         .on_click_handler = cx.updateWith(State, index, State.selectItem),
    ///     }, .{ ui.text(item.description, .{}) }));
    ///     return height;
    /// }
    /// ```
    pub fn virtualList(
        self: *Self,
        id: []const u8,
        list_state: *VirtualListState,
        style: VirtualListStyle,
        comptime render_item: fn (index: u32, cx: *Self) f32,
    ) void {
        const b = self._builder;

        // Sync gap and scroll state
        list_state.gap_px = style.gap;
        b.syncVirtualListScroll(id, list_state);

        // Compute layout parameters
        const params = Builder.computeVirtualListLayout(id, list_state, style);

        // Open viewport and content elements
        const content_id = b.openVirtualListElements(params, style, list_state.scroll_offset_px) orelse return;

        // Top spacer (items above visible range)
        b.renderVirtualListSpacer(params.top_spacer_height);

        // Render visible items with Cx access and cache their heights
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            const height = render_item(i, self);
            list_state.setHeight(i, height);
        }

        // Bottom spacer (items below visible range)
        b.renderVirtualListSpacer(params.bottom_spacer_height);

        // Close content container and viewport
        b.layout.closeElement();
        b.layout.closeElement();

        // Register for scroll handling
        b.registerVirtualListScroll(id, params, content_id, style);
    }

    // =========================================================================
    // Data Table API
    // =========================================================================

    /// Callbacks for data table rendering.
    /// All callbacks receive *Cx for full state/handler access.
    pub fn DataTableCallbacks(comptime CxType: type) type {
        return struct {
            /// Render a header cell. Required.
            render_header: *const fn (col: u32, cx: *CxType) void,

            /// Render a data cell. Required.
            render_cell: *const fn (row: u32, col: u32, cx: *CxType) void,

            /// Optional: Custom row wrapper for row-level styling/click handling.
            /// If null, framework renders a default row container.
            ///
            /// Parameters:
            /// - row: The row index
            /// - visible_cols: The range of visible columns to render
            /// - cx: Context for state access and handlers
            ///
            /// User is responsible for:
            /// 1. Opening a row container with b.layout.openElement()
            /// 2. Iterating visible_cols and calling render_cell for each
            /// 3. Closing the container with b.layout.closeElement()
            render_row: ?*const fn (row: u32, visible_cols: ColRange, cx: *CxType) void = null,
        };
    }

    /// Render a virtualized data table.
    ///
    /// Example:
    /// ```zig
    /// cx.dataTable("table", &state.table_state, .{ .grow = true }, .{
    ///     .render_header = renderHeader,
    ///     .render_cell = renderCell,
    ///     .render_row = renderRow,  // Optional
    /// });
    ///
    /// fn renderHeader(col: u32, cx: *Cx) void {
    ///     const s = cx.stateConst(State);
    ///     cx.render(ui.box(.{
    ///         .on_click_handler = cx.updateWith(State, col, State.sortBy),
    ///     }, .{ ui.text(s.columns[col].name, .{ .weight = .bold }) }));
    /// }
    ///
    /// fn renderCell(row: u32, col: u32, cx: *Cx) void {
    ///     const s = cx.stateConst(State);
    ///     cx.render(ui.box(.{}, .{
    ///         ui.text(s.getCellText(row, col), .{}),
    ///     }));
    /// }
    ///
    /// // Optional: custom row with click handler
    /// fn renderRow(row: u32, visible_cols: ColRange, cx: *Cx) void {
    ///     const s = cx.stateConst(State);
    ///     const b = cx.builder();
    ///     const is_selected = s.selected_row == row;
    ///
    ///     // Open custom row container
    ///     b.layout.openElement(.{
    ///         .layout = .{
    ///             .sizing = .{ .width = .grow(), .height = .fixed(ROW_HEIGHT) },
    ///             .layout_direction = .left_to_right,
    ///         },
    ///         .background_color = if (is_selected) theme.primary else null,
    ///     }) catch return;
    ///
    ///     // Set up click handler on the row
    ///     if (b.dispatch) |d| {
    ///         d.onClickHandler(cx.updateWith(State, row, State.selectRow));
    ///     }
    ///
    ///     // Render visible cells
    ///     var col = visible_cols.start;
    ///     while (col < visible_cols.end) : (col += 1) {
    ///         renderCell(row, col, cx);
    ///     }
    ///
    ///     b.layout.closeElement();
    /// }
    /// ```
    pub fn dataTable(
        self: *Self,
        id: []const u8,
        table_state: *DataTableState,
        style: DataTableStyle,
        comptime callbacks: DataTableCallbacks(Self),
    ) void {
        const b = self._builder;

        // Sync gap from style to state
        table_state.row_gap_px = style.row_gap;

        // Sync scroll state
        b.syncDataTableScroll(id, table_state);

        // Compute layout parameters
        const params = Builder.computeDataTableLayout(id, table_state, style);

        // Open viewport and content elements
        const content_id = b.openDataTableElements(
            params,
            style,
            table_state.scroll_offset_x,
            table_state.scroll_offset_y,
        ) orelse return;

        // Render header row if enabled
        if (table_state.show_header) {
            b.renderDataTableHeaderCx(table_state, params, style, self, callbacks.render_header);
        }

        // Top spacer (rows above visible range)
        if (params.top_spacer > 0) {
            b.renderDataTableSpacer(params.content_width, params.top_spacer);
        }

        // Render visible rows
        const range = params.visible_range;
        var row = range.rows.start;
        while (row < range.rows.end) : (row += 1) {
            if (callbacks.render_row) |render_row| {
                // User controls row container - pass visible column range
                render_row(row, range.cols, self);
            } else {
                // Default row container
                b.renderDataTableRowCx(table_state, row, range.cols, params, style, self, callbacks.render_cell);
            }
        }

        // Bottom spacer (rows below visible range)
        if (params.bottom_spacer > 0) {
            b.renderDataTableSpacer(params.content_width, params.bottom_spacer);
        }

        // Close content container and viewport
        b.layout.closeElement();
        b.layout.closeElement();

        // Register for scroll handling
        b.registerDataTableScroll(id, params, content_id, style);
    }
};

// =============================================================================
// Helper Functions
// =============================================================================

/// Compute a hash for any trigger value for use with animateOn.
/// Uses type-specific handling for common types.
fn computeTriggerHash(comptime T: type, value: T) u64 {
    const info = @typeInfo(T);
    if (info == .bool) return if (value) 1 else 0;
    if (info == .@"enum") return @intFromEnum(value);
    return std.hash.Wyhash.hash(0, std.mem.asBytes(&value));
}

// =============================================================================
// Tests
// =============================================================================

// Note: Tests for typeId, packArg, unpackArg are in core/handler.zig

test "pure state methods are fully testable" {
    // This demonstrates the key benefit of the Cx pattern:
    // State methods have no framework dependencies!
    const AppState = struct {
        count: i32 = 0,
        step: i32 = 1,
        message: []const u8 = "",

        pub fn increment(self: *@This()) void {
            self.count += self.step;
        }

        pub fn decrement(self: *@This()) void {
            self.count -= self.step;
        }

        pub fn setStep(self: *@This(), new_step: i32) void {
            self.step = new_step;
        }

        pub fn reset(self: *@This()) void {
            self.count = 0;
            self.message = "Reset!";
        }

        pub fn addAmount(self: *@This(), amount: i32) void {
            self.count += amount;
        }
    };

    var s = AppState{};

    // Test increment
    s.increment();
    try std.testing.expectEqual(@as(i32, 1), s.count);

    // Test with custom step
    s.setStep(5);
    s.increment();
    try std.testing.expectEqual(@as(i32, 6), s.count);

    // Test decrement
    s.decrement();
    try std.testing.expectEqual(@as(i32, 1), s.count);

    // Test addAmount (simulates updateWith pattern)
    s.addAmount(100);
    try std.testing.expectEqual(@as(i32, 101), s.count);

    // Test reset
    s.reset();
    try std.testing.expectEqual(@as(i32, 0), s.count);
    try std.testing.expectEqualStrings("Reset!", s.message);
}

test "command method signatures are valid" {
    // Verify that command method signatures compile correctly
    const AppState = struct {
        value: i32 = 0,
        focused: bool = false,

        // Command: fn(*State, *Gooey) void
        pub fn doSomethingWithFramework(self: *@This(), g: *Gooey) void {
            _ = g; // Would call g.blurAll(), g.focusTextInput(), etc.
            self.value += 1;
        }

        // CommandWith: fn(*State, *Gooey, Arg) void
        pub fn setValueWithFramework(self: *@This(), g: *Gooey, value: i32) void {
            _ = g;
            self.value = value;
        }

        pub fn focusAndSet(self: *@This(), g: *Gooey, field_id: usize) void {
            _ = g; // Would call g.focusTextInput(...)
            _ = field_id;
            self.focused = true;
        }
    };

    // Just verify the types compile - actual invocation needs Gooey instance
    const s = AppState{};
    try std.testing.expectEqual(@as(i32, 0), s.value);

    // We can still test the logic by calling directly (without Gooey)
    // This shows the pattern encourages testable code
    const MockGooey = Gooey;
    _ = MockGooey;
}

test "handler root state registration" {
    const StateA = struct {
        a: i32 = 10,
        pub fn inc(self: *@This()) void {
            self.a += 1;
        }
    };

    const StateB = struct {
        b: []const u8 = "hello",
    };

    var state_a = StateA{};

    // Set root state
    handler_mod.setRootState(StateA, &state_a);
    defer handler_mod.clearRootState();

    // Retrieve with correct type
    const retrieved = handler_mod.getRootState(StateA);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 10), retrieved.?.a);

    // Modify through pointer
    retrieved.?.inc();
    try std.testing.expectEqual(@as(i32, 11), state_a.a);

    // Wrong type returns null
    const wrong = handler_mod.getRootState(StateB);
    try std.testing.expect(wrong == null);
}

test "Cx.update creates valid HandlerRef" {
    const TestState = struct {
        count: i32 = 0,

        pub fn increment(self: *@This()) void {
            self.count += 1;
        }
    };

    var state = TestState{};
    handler_mod.setRootState(TestState, &state);
    defer handler_mod.clearRootState();

    // Create a minimal Cx (we only need it for the update() method)
    var cx = Cx{
        ._allocator = undefined, // Not used by update()
        ._gooey = undefined, // Not used by update()
        ._builder = undefined, // Not used by update()
        .state_ptr = @ptrCast(&state),
        .state_type_id = typeId(TestState),
    };

    // Create handler
    const handler = cx.update(TestState, TestState.increment);

    // update() handlers use EntityId.invalid (they operate on root state, not an entity)
    try std.testing.expectEqual(EntityId.invalid, handler.entity_id);
}

test "Cx.updateWith creates handler with packed argument" {
    const TestState = struct {
        value: i32 = 0,

        pub fn setValue(self: *@This(), new_value: i32) void {
            self.value = new_value;
        }
    };

    var state = TestState{};
    handler_mod.setRootState(TestState, &state);
    defer handler_mod.clearRootState();

    var cx = Cx{
        ._allocator = undefined,
        ._gooey = undefined,
        ._builder = undefined,
        .state_ptr = @ptrCast(&state),
        .state_type_id = typeId(TestState),
    };

    // Create handler with argument 42
    const handler = cx.updateWith(TestState, @as(i32, 42), TestState.setValue);

    // The argument (42) is packed into entity_id for transport
    const unpacked = unpackArg(i32, handler.entity_id);
    try std.testing.expectEqual(@as(i32, 42), unpacked);
}

test "navigation state pattern" {
    // Common pattern: enum-based page navigation
    const AppState = struct {
        const Page = enum { home, settings, profile, about };

        page: Page = .home,
        previous_page: Page = .home,

        pub fn goToPage(self: *@This(), page: Page) void {
            self.previous_page = self.page;
            self.page = page;
        }

        pub fn goBack(self: *@This()) void {
            const temp = self.page;
            self.page = self.previous_page;
            self.previous_page = temp;
        }

        pub fn goHome(self: *@This()) void {
            self.goToPage(.home);
        }
    };

    var s = AppState{};

    s.goToPage(.settings);
    try std.testing.expectEqual(AppState.Page.settings, s.page);
    try std.testing.expectEqual(AppState.Page.home, s.previous_page);

    s.goToPage(.profile);
    try std.testing.expectEqual(AppState.Page.profile, s.page);

    s.goBack();
    try std.testing.expectEqual(AppState.Page.settings, s.page);

    s.goHome();
    try std.testing.expectEqual(AppState.Page.home, s.page);
}

test "form state pattern" {
    // Common pattern: form with validation
    const FormState = struct {
        name: []const u8 = "",
        email: []const u8 = "",
        agreed_to_terms: bool = false,
        submitted: bool = false,
        error_message: []const u8 = "",

        pub fn setName(self: *@This(), name: []const u8) void {
            self.name = name;
            self.error_message = "";
        }

        pub fn setEmail(self: *@This(), email: []const u8) void {
            self.email = email;
            self.error_message = "";
        }

        pub fn toggleTerms(self: *@This()) void {
            self.agreed_to_terms = !self.agreed_to_terms;
        }

        pub fn submit(self: *@This()) void {
            if (self.name.len == 0) {
                self.error_message = "Name is required";
                return;
            }
            if (self.email.len == 0) {
                self.error_message = "Email is required";
                return;
            }
            if (!self.agreed_to_terms) {
                self.error_message = "You must agree to terms";
                return;
            }
            self.submitted = true;
            self.error_message = "";
        }

        pub fn reset(self: *@This()) void {
            self.* = .{};
        }
    };

    var form = FormState{};

    // Test validation
    form.submit();
    try std.testing.expectEqualStrings("Name is required", form.error_message);
    try std.testing.expect(!form.submitted);

    form.setName("John");
    form.submit();
    try std.testing.expectEqualStrings("Email is required", form.error_message);

    form.setEmail("john@example.com");
    form.submit();
    try std.testing.expectEqualStrings("You must agree to terms", form.error_message);

    form.toggleTerms();
    form.submit();
    try std.testing.expectEqualStrings("", form.error_message);
    try std.testing.expect(form.submitted);

    // Test reset
    form.reset();
    try std.testing.expectEqualStrings("", form.name);
    try std.testing.expect(!form.submitted);
}

test "counter with bounds pattern" {
    // Common pattern: bounded counter
    const BoundedCounter = struct {
        value: i32 = 0,
        min: i32 = 0,
        max: i32 = 100,

        pub fn increment(self: *@This()) void {
            if (self.value < self.max) {
                self.value += 1;
            }
        }

        pub fn decrement(self: *@This()) void {
            if (self.value > self.min) {
                self.value -= 1;
            }
        }

        pub fn setValue(self: *@This(), value: i32) void {
            self.value = @max(self.min, @min(self.max, value));
        }

        pub fn isAtMin(self: *const @This()) bool {
            return self.value == self.min;
        }

        pub fn isAtMax(self: *const @This()) bool {
            return self.value == self.max;
        }
    };

    var counter = BoundedCounter{ .min = -10, .max = 10 };

    // Test bounds
    counter.setValue(100);
    try std.testing.expectEqual(@as(i32, 10), counter.value);
    try std.testing.expect(counter.isAtMax());

    counter.setValue(-100);
    try std.testing.expectEqual(@as(i32, -10), counter.value);
    try std.testing.expect(counter.isAtMin());

    // Can't go past bounds
    counter.decrement();
    try std.testing.expectEqual(@as(i32, -10), counter.value);

    counter.setValue(10);
    counter.increment();
    try std.testing.expectEqual(@as(i32, 10), counter.value);
}

test "toggle collection pattern" {
    // Common pattern: multi-select with toggles
    const SelectionState = struct {
        selected: [8]bool = [_]bool{false} ** 8,
        count: usize = 8,

        pub fn toggle(self: *@This(), index: usize) void {
            if (index < self.count) {
                self.selected[index] = !self.selected[index];
            }
        }

        pub fn selectAll(self: *@This()) void {
            for (0..self.count) |i| {
                self.selected[i] = true;
            }
        }

        pub fn clearAll(self: *@This()) void {
            for (0..self.count) |i| {
                self.selected[i] = false;
            }
        }

        pub fn selectedCount(self: *const @This()) usize {
            var c: usize = 0;
            for (0..self.count) |i| {
                if (self.selected[i]) c += 1;
            }
            return c;
        }
    };

    var sel = SelectionState{};

    try std.testing.expectEqual(@as(usize, 0), sel.selectedCount());

    sel.toggle(0);
    sel.toggle(3);
    sel.toggle(5);
    try std.testing.expectEqual(@as(usize, 3), sel.selectedCount());

    sel.toggle(3); // Deselect
    try std.testing.expectEqual(@as(usize, 2), sel.selectedCount());

    sel.selectAll();
    try std.testing.expectEqual(@as(usize, 8), sel.selectedCount());

    sel.clearAll();
    try std.testing.expectEqual(@as(usize, 0), sel.selectedCount());
}

test "DataTableCallbacks type structure" {
    // Verify that DataTableCallbacks can be instantiated with the expected fields
    const TestCx = Cx;

    const Callbacks = TestCx.DataTableCallbacks(TestCx);

    // Verify the struct has the expected fields
    const info = @typeInfo(Callbacks);
    try std.testing.expectEqual(@as(usize, 3), info.@"struct".fields.len);

    // Verify field names
    try std.testing.expectEqualStrings("render_header", info.@"struct".fields[0].name);
    try std.testing.expectEqualStrings("render_cell", info.@"struct".fields[1].name);
    try std.testing.expectEqualStrings("render_row", info.@"struct".fields[2].name);

    // Verify render_row has a default value (is optional)
    try std.testing.expect(info.@"struct".fields[2].default_value_ptr != null);
}
