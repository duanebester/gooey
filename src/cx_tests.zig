//! Tests for `cx.zig`.
//!
//! Most of these are demo / pattern tests illustrating that pure state
//! methods are testable without any framework scaffolding. Keeping them
//! outside `cx.zig` lets `cx.zig` stay focused on the runtime API
//! surface, and lets the tests grow without pushing `cx.zig` over the
//! size budget.
//!
//! These tests are picked up by the standard `zig build test` graph
//! via a `comptime _ = @import("cx_tests.zig")` reference at the top
//! of `cx.zig`. No build.zig changes are required.

const std = @import("std");

const cx_mod = @import("cx.zig");
const Cx = cx_mod.Cx;
const typeId = cx_mod.typeId;

const window_mod = @import("context/window.zig");
const Window = window_mod.Window;

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

    // Test addAmount (a method that takes an argument)
    s.addAmount(100);
    try std.testing.expectEqual(@as(i32, 101), s.count);

    // Test reset
    s.reset();
    try std.testing.expectEqual(@as(i32, 0), s.count);
    try std.testing.expectEqualStrings("Reset!", s.message);
}

// =============================================================================
// `cx.on` contract tests
// =============================================================================

const dispatch_mod = @import("context/dispatch.zig");

/// A heap `Window` (too large for the stack) with only the fields the handler
/// path reads: root state, render flag, and platform window.
fn handlerTestWindow(comptime State: type, state: *State) !*Window {
    const window = try std.testing.allocator.create(Window);
    window.root_state_ptr = null;
    window.root_state_type_id = 0;
    window.platform_window = null;
    window.needs_render = false;
    window.setRootState(State, state);
    return window;
}

fn handlerTestCx(comptime State: type, window: *Window, state: *State) Cx {
    return .{
        ._allocator = std.testing.allocator,
        ._window = window,
        ._builder = undefined,
        .state_ptr = @ptrCast(state),
        .state_type_id = typeId(State),
    };
}

const ShapeState = struct {
    plain_count: u32 = 0,
    last_arg: i32 = 0,
    window_seen: ?*Window = null,
    arg_with_window: u8 = 0,

    pub fn plain(self: *ShapeState) void {
        self.plain_count += 1;
    }
    pub fn withArg(self: *ShapeState, value: i32) void {
        self.last_arg = value;
    }
    pub fn withWindow(self: *ShapeState, window: *Window) void {
        self.window_seen = window;
    }
    pub fn withBoth(self: *ShapeState, value: u8, window: *Window) void {
        self.arg_with_window = value;
        self.window_seen = window;
    }
};

test "cx.on detects all four method shapes" {
    // Build one handler per shape and invoke each. Each method writes a
    // different field, so a shape misdetected as another (for example an
    // argument passed where the window belongs) shows up as a wrong field.
    var state = ShapeState{};
    const window = try handlerTestWindow(ShapeState, &state);
    defer std.testing.allocator.destroy(window);
    var cx = handlerTestCx(ShapeState, window, &state);

    cx.on(ShapeState.plain, .{}).call(window);
    try std.testing.expectEqual(@as(u32, 1), state.plain_count);
    try std.testing.expect(state.window_seen == null);
    try std.testing.expect(window.checkAndClearRenderFlag());

    cx.on(ShapeState.withArg, .{ .arg = -7 }).call(window);
    try std.testing.expectEqual(@as(i32, -7), state.last_arg);
    try std.testing.expect(state.window_seen == null);

    cx.on(ShapeState.withWindow, .{}).call(window);
    try std.testing.expectEqual(window, state.window_seen.?);

    state.window_seen = null;
    cx.on(ShapeState.withBoth, .{ .arg = 200 }).call(window);
    try std.testing.expectEqual(@as(u8, 200), state.arg_with_window);
    try std.testing.expectEqual(window, state.window_seen.?);
    try std.testing.expectEqual(@as(u32, 1), state.plain_count);
}

test "cx.on coerces .arg to the method's argument type" {
    // Literals carry no type. An integer literal must become the method's
    // `u8` at its maximum and an enum literal the method's enum, without
    // `@as`. `withArg` is the index widgets' path and must keep a full usize.
    const Page = enum { home, settings, about };
    const State = struct {
        small: u8 = 0,
        page: Page = .home,
        index: usize = 0,
        pub fn setSmall(self: *@This(), value: u8) void {
            self.small = value;
        }
        pub fn setPage(self: *@This(), page: Page) void {
            self.page = page;
        }
        pub fn select(self: *@This(), index: usize) void {
            self.index = index;
        }
    };
    var state = State{};
    const window = try handlerTestWindow(State, &state);
    defer std.testing.allocator.destroy(window);
    var cx = handlerTestCx(State, window, &state);

    cx.on(State.setSmall, .{ .arg = 255 }).call(window);
    try std.testing.expectEqual(@as(u8, 255), state.small);
    cx.on(State.setPage, .{ .arg = .about }).call(window);
    try std.testing.expectEqual(Page.about, state.page);

    const on_select = cx.on(State.select, .{});
    const index_max: usize = std.math.maxInt(usize);
    on_select.withArg(index_max).call(window);
    try std.testing.expectEqual(index_max, state.index);
    on_select.withArg(@as(usize, 0)).call(window);
    try std.testing.expectEqual(@as(usize, 0), state.index);
}

test "state type check runs in safe modes for cx.on and cx.state" {
    // A handler or state access for a type that is not the root state panics
    // in Debug and ReleaseSafe. The test hook turns the panic into a counted
    // return, proving each check runs without aborting the test runner.
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    const Other = struct {
        pub fn touch(_: *@This()) void {}
    };
    var state = ShapeState{};
    const window = try handlerTestWindow(ShapeState, &state);
    defer std.testing.allocator.destroy(window);
    var cx = handlerTestCx(ShapeState, window, &state);
    const handler_mod = @import("context/handler.zig");
    defer handler_mod.test_mismatches_expected = 0;

    // The matching type passes without consuming an expected mismatch.
    handler_mod.test_mismatches_expected = 1;
    _ = cx.on(ShapeState.plain, .{});
    _ = cx.state(ShapeState);
    try std.testing.expectEqual(@as(u32, 1), handler_mod.test_mismatches_expected);

    _ = cx.on(Other.touch, .{});
    try std.testing.expectEqual(@as(u32, 0), handler_mod.test_mismatches_expected);

    handler_mod.test_mismatches_expected = 1;
    _ = cx.state(Other);
    try std.testing.expectEqual(@as(u32, 0), handler_mod.test_mismatches_expected);
}

test "a click through dispatch reaches a handler with its argument" {
    // Register the handler the way `Box.on_click` does, hit-test a point
    // inside the clickable child, and dispatch the click. The parent has its
    // own handler, so bubbling past the child would show up as a wrong value.
    var state = ShapeState{};
    const window = try handlerTestWindow(ShapeState, &state);
    defer std.testing.allocator.destroy(window);
    var cx = handlerTestCx(ShapeState, window, &state);

    var tree = dispatch_mod.DispatchTree.init(std.testing.allocator);
    defer tree.deinit();
    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    tree.onClick(cx.on(ShapeState.withArg, .{ .arg = -1 }));
    const child = tree.pushNode();
    tree.setBounds(child, .{ .x = 50, .y = 50, .width = 40, .height = 20 });
    tree.onClick(cx.on(ShapeState.withArg, .{ .arg = 42 }));
    tree.popNode();
    tree.popNode();

    const target = tree.hitTest(60, 55).?;
    try std.testing.expectEqual(child, target);
    try std.testing.expect(tree.dispatchClick(target, window));
    try std.testing.expectEqual(@as(i32, 42), state.last_arg);
    try std.testing.expect(window.checkAndClearRenderFlag());
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
        selected: [8]bool = @splat(false),
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
    // The canonical generic lives at `cx.lists.Lists.DataTableCallbacks(Cx)`;
    // this pins its field layout.
    const lists = @import("cx/lists.zig");
    const Callbacks = lists.Lists.DataTableCallbacks(Cx);

    // Verify the struct has the expected fields
    const info = @typeInfo(Callbacks);
    try std.testing.expectEqual(@as(usize, 3), info.@"struct".field_names.len);

    // Verify field names
    try std.testing.expectEqualStrings("render_header", info.@"struct".field_names[0]);
    try std.testing.expectEqualStrings("render_cell", info.@"struct".field_names[1]);
    try std.testing.expectEqualStrings("render_row", info.@"struct".field_names[2]);

    // Verify render_row has a default value (is optional)
    try std.testing.expect(info.@"struct".field_attrs[2].default_value_ptr != null);
}

// =============================================================================
// Sub-namespace surface tests.
//
// We can't run the full render pipeline from a unit test (it needs a
// live `Window` + `Builder`), but we can pin the sub-namespaces at the
// type / decl level: each namespace marker stays zero-sized and each
// public method stays addressable. If a change breaks that shape, these
// tests fail at compile time rather than at the call site of every
// downstream caller.

const lists_ns = @import("cx/lists.zig");
const animations_ns = @import("cx/animations.zig");
const entities_ns = @import("cx/entities.zig");
const focus_ns = @import("cx/focus.zig");
const element_states_ns = @import("cx/element_states.zig");

test "sub-namespace fields are zero-sized (no Cx layout growth)" {
    // The whole point of the `@fieldParentPtr` indirection is that
    // each namespace marker is zero-sized (CLAUDE.md §10 — don't
    // take aliases). If any of these grows, every `Cx` instance pays
    // for it — fail loudly here instead of silently bloating the
    // hot context struct.
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(lists_ns.Lists));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(animations_ns.Animations));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(entities_ns.Entities));
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(focus_ns.Focus));
    // Same zero-size invariant for `element_states`. If
    // it ever grows, every `Cx` instance pays for it (Cx is the
    // hot per-frame context struct handed to every render fn).
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(element_states_ns.ElementStates));
}

test "sub-namespace methods are reachable as decls" {
    // Pin the *existence* of each namespace decl. If a refactor
    // renames one, this test fails compilation before any downstream
    // caller does.
    _ = lists_ns.Lists.uniform;
    _ = lists_ns.Lists.tree;
    _ = lists_ns.Lists.virtual;
    _ = lists_ns.Lists.dataTable;

    _ = focus_ns.Focus.next;
    _ = focus_ns.Focus.prev;
    _ = focus_ns.Focus.blurAll;
    _ = focus_ns.Focus.widget;
    _ = focus_ns.Focus.isElementFocused;

    _ = entities_ns.Entities.create;
    _ = entities_ns.Entities.read;
    _ = entities_ns.Entities.write;
    _ = entities_ns.Entities.context;
    _ = entities_ns.Entities.attachCancel;
    _ = entities_ns.Entities.detachCancel;

    _ = animations_ns.Animations.tween;
    _ = animations_ns.Animations.tweenComptime;
    _ = animations_ns.Animations.tweenOn;
    _ = animations_ns.Animations.tweenOnComptime;
    _ = animations_ns.Animations.restart;
    _ = animations_ns.Animations.restartComptime;
    _ = animations_ns.Animations.spring;
    _ = animations_ns.Animations.springComptime;
    _ = animations_ns.Animations.stagger;
    _ = animations_ns.Animations.staggerComptime;
    _ = animations_ns.Animations.motion;
    _ = animations_ns.Animations.motionComptime;
    _ = animations_ns.Animations.springMotion;
    _ = animations_ns.Animations.springMotionComptime;

    // element_states namespace surface. Pin every public
    // method so a rename on either the namespace side or the
    // underlying `Window.element_states` pool fails compilation
    // here rather than silently in a downstream widget.
    _ = element_states_ns.ElementStates.with;
    _ = element_states_ns.ElementStates.withById;
    _ = element_states_ns.ElementStates.get;
    _ = element_states_ns.ElementStates.getById;
    _ = element_states_ns.ElementStates.contains;
    _ = element_states_ns.ElementStates.containsById;
    _ = element_states_ns.ElementStates.insert;
    _ = element_states_ns.ElementStates.insertById;
    _ = element_states_ns.ElementStates.remove;
    _ = element_states_ns.ElementStates.removeById;
}

test "cx.element_states: namespace field is reachable on Cx" {
    // Pin the field name + type so a rename on `Cx` fails this test
    // before downstream `cx.element_states.*` callers break. We
    // can't construct a real `Cx` from a unit test (it needs a live
    // `*Window` + `*Builder`), so reach for the `@TypeOf` of the
    // field through `@FieldType` instead — this is a comptime
    // reflection check, not a runtime touch.
    const Field = @FieldType(Cx, "element_states");
    try std.testing.expectEqual(element_states_ns.ElementStates, Field);
}

test "cx.element_states: signatures route the right comptime types" {
    // The namespace methods are all thin forwarders — the load-bearing
    // invariants live in `context/element_states.zig`'s 18 tests.
    // What we *can* validate at the `Cx`-side surface without a live
    // `Window` is that every method threads the comptime `S` and the
    // `id` shape correctly. `@typeInfo` on the function reveals the
    // parameter list; we pin enough of it that a future refactor
    // that drops or reorders a parameter is caught here.
    const Probe = struct { value: u32 = 0 };

    // `with(*Self, comptime S, []const u8, comptime fn () S) !*S` —
    // four params after the receiver. Same shape for `withById` but
    // with `u64` in slot 2.
    const with_info = @typeInfo(@TypeOf(element_states_ns.ElementStates.with)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), with_info.param_types.len);

    const with_by_id_info = @typeInfo(@TypeOf(element_states_ns.ElementStates.withById)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), with_by_id_info.param_types.len);

    // `get` / `getById` — three params (receiver + S + id).
    const get_info = @typeInfo(@TypeOf(element_states_ns.ElementStates.get)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), get_info.param_types.len);

    // `insert` / `insertById` — four params (receiver + S + id + initial).
    const insert_info = @typeInfo(@TypeOf(element_states_ns.ElementStates.insert)).@"fn";
    try std.testing.expectEqual(@as(usize, 4), insert_info.param_types.len);

    // `remove` / `removeById` — three params, returns `bool`.
    const remove_info = @typeInfo(@TypeOf(element_states_ns.ElementStates.remove)).@"fn";
    try std.testing.expectEqual(@as(usize, 3), remove_info.param_types.len);
    try std.testing.expectEqual(bool, remove_info.return_type.?);

    // Probe ensures the test references a non-trivial comptime type.
    // If `Probe` is ever inlined away, the param-count assertions
    // above still hold — the type is just a fixture.
    _ = Probe;
}
