//! Cx - The Unified Rendering Context
//!
//! Provides access to:
//! - Layout building (box, vstack, hstack, etc.)
//! - Application state
//! - Window operations
//! - Entity system
//! - Focus management
//!
//! ## Migration from Context(T)
//!
//! Before (Context pattern):
//! ```zig
//! fn render(cx: *gooey.Context(AppState)) void {
//!     const s = cx.state();
//!     cx.vstack(.{}, .{...});
//! }
//! ```
//!
//! After (Cx pattern):
//! ```zig
//! fn render(cx: *gooey.Cx) void {
//!     const s = cx.state(AppState);
//!     cx.vstack(.{}, .{...});
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
//!     cx.box(.{
//!         .width = size.width,
//!         .height = size.height,
//!     }, .{
//!         gooey.ui.textFmt("Count: {}", .{s.count}, .{}),
//!         gooey.Button{ .label = "+", .on_click_handler = cx.update(AppState, AppState.increment) },
//!         gooey.Button{ .label = "Reset", .on_click_handler = cx.updateWith(AppState, @as(i32, 0), AppState.setCount) },
//!     });
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
const scroll_view_mod = @import("widgets/scroll_container.zig");

// Animation types (re-exported from root.zig for users)
const animation_mod = @import("animation/mod.zig");
const Animation = animation_mod.AnimationConfig;
const AnimationHandle = animation_mod.AnimationHandle;

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
const Box = ui_mod.Box;
const StackStyle = ui_mod.StackStyle;
const CenterStyle = ui_mod.CenterStyle;
const ScrollStyle = ui_mod.ScrollStyle;
const Theme = ui_mod.Theme;

/// Cx - The unified rendering context
///
/// Provides a single entry point for:
/// - State access: `cx.state(AppState)`
/// - Layout building: `cx.box()`, `cx.vstack()`, etc.
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
            const mac_window = platform.mac.window;
            const window: *mac_window.Window = @ptrCast(@alignCast(self._gooey.window.ptr));
            window.performClose();
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
                const state_ptr = handler_mod.getRootState(State) orelse return;
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
                const state_ptr = handler_mod.getRootState(State) orelse return;
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
                const state_ptr = handler_mod.getRootState(State) orelse return;
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
                const state_ptr = handler_mod.getRootState(State) orelse return;
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

    /// Get a scroll view widget by ID.
    pub fn scrollView(self: *Self, id: []const u8) ?*scroll_view_mod.ScrollContainer {
        return self._gooey.widgets.scrollContainer(id);
    }

    // =========================================================================
    // Layout Building - Delegates to Builder
    // =========================================================================

    /// Create a box container with the given style and children.
    pub fn box(self: *Self, style: Box, children: anytype) void {
        self._builder.box(style, children);
    }

    /// Create a box container with source location tracking (Phase 5).
    /// Usage: cx.boxTracked(.{ ... }, .{ ... }, @src())
    pub fn boxTracked(self: *Self, style: Box, children: anytype, src: std.builtin.SourceLocation) void {
        self._builder.boxTracked(style, children, src);
    }

    /// Create a box container with an explicit ID.
    pub fn boxWithId(self: *Self, id: []const u8, style: Box, children: anytype) void {
        self._builder.boxWithId(id, style, children);
    }

    /// Create a vertical stack (column).
    pub fn vstack(self: *Self, style: StackStyle, children: anytype) void {
        self._builder.vstack(style, children);
    }

    /// Create a vertical stack with source location tracking (Phase 5).
    /// Usage: cx.vstackTracked(.{ ... }, .{ ... }, @src())
    pub fn vstackTracked(self: *Self, style: StackStyle, children: anytype, src: std.builtin.SourceLocation) void {
        self._builder.vstackTracked(style, children, src);
    }

    /// Create a horizontal stack (row).
    pub fn hstack(self: *Self, style: StackStyle, children: anytype) void {
        self._builder.hstack(style, children);
    }

    /// Create a horizontal stack with source location tracking (Phase 5).
    /// Usage: cx.hstackTracked(.{ ... }, .{ ... }, @src())
    pub fn hstackTracked(self: *Self, style: StackStyle, children: anytype, src: std.builtin.SourceLocation) void {
        self._builder.hstackTracked(style, children, src);
    }

    /// Center children in available space.
    pub fn center(self: *Self, style: CenterStyle, children: anytype) void {
        self._builder.center(style, children);
    }

    /// Create a scrollable container.
    pub fn scroll(self: *Self, id: []const u8, style: ScrollStyle, children: anytype) void {
        self._builder.scroll(id, style, children);
    }

    // =========================================================================
    // Conditionals
    // =========================================================================

    /// Render children only if condition is true.
    pub fn when(self: *Self, condition: bool, children: anytype) void {
        self._builder.when(condition, children);
    }

    /// Render with value if optional is non-null.
    pub fn maybe(self: *Self, optional: anytype, comptime render_fn: anytype) void {
        self._builder.maybe(optional, render_fn);
    }

    /// Render for each item in a slice.
    pub fn each(self: *Self, items: anytype, comptime render_fn: anytype) void {
        self._builder.each(items, render_fn);
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
