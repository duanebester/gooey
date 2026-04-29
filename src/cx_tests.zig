//! Tests for `cx.zig`.
//!
//! Split out of `cx.zig` in PR 5 — the bulk of the file's line budget
//! was demo / pattern tests illustrating that pure state methods are
//! testable without any framework scaffolding. Keeping them here lets
//! `cx.zig` stay focused on the runtime API surface, and lets the
//! tests grow without pushing `cx.zig` back over the size budget.
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

const handler_mod = @import("context/handler.zig");
const EntityId = handler_mod.EntityId;
const unpackArg = handler_mod.unpackArg;

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

        // Command: fn(*State, *Window) void
        pub fn doSomethingWithFramework(self: *@This(), g: *Window) void {
            _ = g; // Would call g.blurAll(), g.focusTextInput(), etc.
            self.value += 1;
        }

        // CommandWith: fn(*State, *Window, Arg) void
        pub fn setValueWithFramework(self: *@This(), g: *Window, value: i32) void {
            _ = g;
            self.value = value;
        }

        pub fn focusAndSet(self: *@This(), g: *Window, field_id: usize) void {
            _ = g; // Would call g.focusTextInput(...)
            _ = field_id;
            self.focused = true;
        }
    };

    // Just verify the types compile - actual invocation needs Window instance
    const s = AppState{};
    try std.testing.expectEqual(@as(i32, 0), s.value);

    // We can still test the logic by calling directly (without Window)
    // This shows the pattern encourages testable code
    const MockWindow = Window;
    _ = MockWindow;
}

test "root state registration via Window instance" {
    const StateA = struct {
        a: i32 = 10,
        pub fn inc(self: *@This()) void {
            self.a += 1;
        }
    };

    const StateB = struct {
        b: []const u8 = "hello",
    };

    // Heap-allocate Window (>400KB — too large for stack per CLAUDE.md).
    const window = try std.testing.allocator.create(Window);
    defer std.testing.allocator.destroy(window);

    window.root_state_ptr = null;
    window.root_state_type_id = 0;

    var state_a = StateA{};

    // Set root state on the Window instance.
    window.setRootState(StateA, &state_a);
    defer window.clearRootState();

    // Retrieve with correct type.
    const retrieved = window.getRootState(StateA);
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqual(@as(i32, 10), retrieved.?.a);

    // Modify through pointer.
    retrieved.?.inc();
    try std.testing.expectEqual(@as(i32, 11), state_a.a);

    // Wrong type returns null.
    const wrong = window.getRootState(StateB);
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

    // Create a minimal Cx (we only need it for the update() method).
    // No root state registration needed — the handler is not invoked here.
    var cx = Cx{
        ._allocator = undefined, // Not used by update()
        ._window = undefined, // Not used by update()
        ._builder = undefined, // Not used by update()
        .state_ptr = @ptrCast(&state),
        .state_type_id = typeId(TestState),
    };

    // Create handler
    const handler = cx.update(TestState.increment);

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

    // No root state registration needed — the handler is not invoked here.
    var cx = Cx{
        ._allocator = undefined,
        ._window = undefined,
        ._builder = undefined,
        .state_ptr = @ptrCast(&state),
        .state_type_id = typeId(TestState),
    };

    // Create handler with argument 42
    const handler = cx.updateWith(@as(i32, 42), TestState.setValue);

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

// =============================================================================
// PR 5 — sub-namespacing equivalence tests.
//
// The cleanup plan's PR 5 definition-of-done states:
//   "Both `cx.uniformList(…)` and `cx.lists.uniform(…)` work and
//    produce identical output."
//
// We can't run the full render pipeline from a unit test (it needs a
// live `Window` + `Builder`), but we can pin the equivalence at the
// type / decl level: the deprecated forwarders on `Cx` and the new
// sub-namespace methods must share argument types and return types,
// and `DataTableCallbacks` must be the *same* type from both
// namespaces. If a future change breaks the forwarder shape, these
// tests fail at compile time rather than at the call site of every
// downstream caller.

const lists_ns = @import("cx/lists.zig");
const animations_ns = @import("cx/animations.zig");
const entities_ns = @import("cx/entities.zig");
const focus_ns = @import("cx/focus.zig");

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
}

test "DataTableCallbacks: deprecated alias produces same type as cx.lists" {
    // Zig caches comptime function results by argument identity, so
    // both calls return the *same* type — callers using either name
    // can hand their struct literal to either API.
    const Via_Cx = Cx.DataTableCallbacks(Cx);
    const Via_Lists = lists_ns.Lists.DataTableCallbacks(Cx);
    try std.testing.expectEqual(Via_Cx, Via_Lists);
}

test "sub-namespace methods are reachable as decls" {
    // The deprecated forwarders on `Cx` and the namespace methods
    // necessarily differ in receiver type (`*Cx` vs `*Lists` etc.),
    // so we can't assert `@TypeOf(...) == @TypeOf(...)`. Instead pin
    // the *existence* of each new-namespace decl. If a refactor
    // renames one side of the pair, this test fails compilation
    // before any downstream caller does. The forwarder bodies in
    // `cx.zig` provide the runtime equivalence — they're literally
    // one-line calls into these decls.
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
}
