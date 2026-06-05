//! Todo Example (Cx API)
//!
//! A compact, end-to-end app that exercises a broad slice of the public
//! surface in one place. It is the example the README's "Quick Start"
//! mirrors, so keep the two in sync.
//!
//! Demonstrates:
//! - Pure state methods + `cx.update` (toggle-free mutations like clearCompleted)
//! - `cx.updateWith` with a packed index argument (toggle / remove a row)
//! - `cx.updateWith` with a packed enum argument (filter switch)
//! - `cx.command` for framework access (clearing the input widget's buffer)
//! - `TextInput` two-way binding via `.bind`
//! - `Checkbox`, `Button` variants/sizes
//! - Layout with `ui.box` (backgrounds, `{ .main, .cross }` alignment) vs
//!   `ui.hstack` / `ui.vstack` (gap + simple alignment only)
//! - `ui.text` / `ui.textFmt`, `ui.spacer`, conditional rendering by hand
//! - Pure, UI-free unit tests over the state model

const std = @import("std");

const gooey = @import("gooey");
const platform = gooey.platform;

/// Route std.log through the console on WASM, default logFn on native.
pub const std_options = gooey.std_options;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.components.Button;
const Checkbox = gooey.components.Checkbox;
const TextInput = gooey.components.TextInput;

// =============================================================================
// Limits (CLAUDE.md §4 — a hard cap on everything)
// =============================================================================

const MAX_TODOS = 64;
const TEXT_CAP = 128;

/// Stable layout id for the draft input. Used both to render the field and to
/// reach its retained widget buffer from `addTodo` so we can clear it.
const draft_input_id = "new-todo";

// =============================================================================
// Models
// =============================================================================

/// One todo. The text is copied into a fixed inline buffer so the model owns
/// its bytes outright — no allocator, no lifetime coupling to the input widget.
const Todo = struct {
    buf: [TEXT_CAP]u8 = @splat(0),
    len: usize = 0,
    done: bool = false,

    fn text(self: *const Todo) []const u8 {
        return self.buf[0..self.len];
    }
};

const Filter = enum { all, active, done };

// =============================================================================
// Application State — pure, fully testable without any UI
// =============================================================================

const AppState = struct {
    todos: [MAX_TODOS]Todo = @splat(.{}),
    count: usize = 0,
    /// Bound to the TextInput; the widget writes the live text back here each
    /// frame (widget -> state only — see `addTodo` for why clearing is manual).
    draft: []const u8 = "",
    filter: Filter = .all,

    // -------------------------------------------------------------------------
    // Pure logic (no Cx, no Window) — these are what the tests below drive.
    // -------------------------------------------------------------------------

    /// Append `value` as a new todo. No-op when blank or at capacity, so the
    /// caller never has to pre-check. Split out from `addTodo` so the append
    /// path is testable without a live widget.
    fn pushTodo(self: *AppState, value: []const u8) void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.count >= MAX_TODOS) return;

        const slot = &self.todos[self.count];
        const n = @min(trimmed.len, TEXT_CAP);
        @memcpy(slot.buf[0..n], trimmed[0..n]);
        slot.len = n;
        slot.done = false;
        self.count += 1;
    }

    pub fn toggle(self: *AppState, index: usize) void {
        if (index >= self.count) return;
        self.todos[index].done = !self.todos[index].done;
    }

    pub fn remove(self: *AppState, index: usize) void {
        if (index >= self.count) return;
        // Shift the tail down one slot to keep [0..count) contiguous.
        var i = index;
        while (i + 1 < self.count) : (i += 1) {
            self.todos[i] = self.todos[i + 1];
        }
        self.count -= 1;
    }

    pub fn setFilter(self: *AppState, filter: Filter) void {
        self.filter = filter;
    }

    pub fn clearCompleted(self: *AppState) void {
        var write: usize = 0;
        var read: usize = 0;
        while (read < self.count) : (read += 1) {
            if (!self.todos[read].done) {
                self.todos[write] = self.todos[read];
                write += 1;
            }
        }
        self.count = write;
    }

    fn remaining(self: *const AppState) u32 {
        var n: u32 = 0;
        for (self.todos[0..self.count]) |*todo| {
            if (!todo.done) n += 1;
        }
        return n;
    }

    fn visible(self: *const AppState, todo: *const Todo) bool {
        return switch (self.filter) {
            .all => true,
            .active => !todo.done,
            .done => todo.done,
        };
    }

    // -------------------------------------------------------------------------
    // Command — needs Window access, so it goes through `cx.command`.
    // -------------------------------------------------------------------------

    /// Add the current draft, then clear the input. The binding only flows
    /// widget -> state, so zeroing `self.draft` is not enough; we reach the
    /// retained `TextInputState` by its string id and clear its buffer.
    pub fn addTodo(self: *AppState, g: *gooey.Window) void {
        self.pushTodo(self.draft);
        self.draft = "";

        if (g.widgetState(gooey.widgets.TextInputState, draft_input_id)) |input| {
            input.clear();
        }
    }
};

// =============================================================================
// Entry Point
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "Todos",
    .width = 480,
    .height = 560,
});

// Force type analysis — triggers @export on WASM.
comptime {
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    return App.main(init);
}

// =============================================================================
// Render
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .direction = .column,
        .padding = .{ .all = 24 },
        .gap = 16,
        .background = ui.Color.rgb(0.96, 0.96, 0.97),
    }, .{
        ui.text("Todos", .{ .size = 28, .color = ui.Color.rgb(0.1, 0.1, 0.15) }),
        InputRow{},
        FilterBar{},
        TodoList{},
        ui.spacer(),
        Footer{},
    }));
}

// =============================================================================
// Components
// =============================================================================

/// Text field + Add button. The field binds straight to `state.draft`; Add is
/// a command because it has to clear the input widget after appending.
const InputRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            TextInput{
                .id = draft_input_id,
                .placeholder = "What needs doing?",
                .bind = &s.draft,
                .fill_width = true,
            },
            Button{ .label = "Add", .on_click_handler = cx.command(AppState.addTodo) },
        }));
    }
};

/// All / Active / Done. Each button packs its `Filter` into the handler arg.
const FilterBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.hstack(.{ .gap = 8 }, .{
            FilterButton{ .label = "All", .filter = .all, .active = s.filter == .all },
            FilterButton{ .label = "Active", .filter = .active, .active = s.filter == .active },
            FilterButton{ .label = "Done", .filter = .done, .active = s.filter == .done },
        }));
    }
};

const FilterButton = struct {
    label: []const u8,
    filter: Filter,
    active: bool,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(Button{
            .label = self.label,
            .size = .small,
            .variant = if (self.active) .primary else .secondary,
            .on_click_handler = cx.updateWith(self.filter, AppState.setFilter),
        });
    }
};

/// The list, or an empty-state hint when there is nothing to show.
const TodoList = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        if (s.count == 0) {
            cx.render(ui.text(
                "Nothing yet — add your first todo above.",
                .{ .size = 14, .color = ui.Color.rgb(0.5, 0.5, 0.55) },
            ));
            return;
        }

        cx.render(ui.vstack(.{ .gap = 8 }, .{TodoItems{}}));
    }
};

/// Loops the model and emits one `TodoRow` per visible item. Iteration lives
/// in a component (not `ui.each`) because each row needs `cx` to build its
/// per-row handlers.
const TodoItems = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        for (s.todos[0..s.count], 0..) |*todo, index| {
            if (!s.visible(todo)) continue;
            cx.render(TodoRow{ .index = index, .done = todo.done, .label = todo.text() });
        }
    }
};

const TodoRow = struct {
    index: usize,
    done: bool,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        // A row needs a background + vertical centering, so it is a `box`
        // (with `.direction = .row`), not an `hstack` — stacks carry only
        // gap/alignment/padding.
        cx.render(ui.box(.{
            .direction = .row,
            .gap = 12,
            .alignment = .{ .cross = .center },
            .padding = .{ .all = 10 },
            .background = ui.Color.white,
            .corner_radius = 8,
        }, .{
            Checkbox{
                .checked = self.done,
                .on_click_handler = cx.updateWith(self.index, AppState.toggle),
            },
            ui.text(self.label, .{
                .size = 16,
                .color = if (self.done)
                    ui.Color.rgb(0.6, 0.6, 0.6)
                else
                    ui.Color.rgb(0.1, 0.1, 0.1),
            }),
            ui.spacer(),
            Button{
                .label = "Delete",
                .variant = .danger,
                .size = .small,
                .on_click_handler = cx.updateWith(self.index, AppState.remove),
            },
        }));
    }
};

/// Remaining count + a pure "clear completed" action.
const Footer = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.hstack(.{ .gap = 12, .alignment = .center }, .{
            ui.textFmt("{d} left", .{s.remaining()}, .{
                .size = 14,
                .color = ui.Color.rgb(0.4, 0.4, 0.45),
            }),
            ui.spacer(),
            Button{
                .label = "Clear completed",
                .variant = .secondary,
                .size = .small,
                .on_click_handler = cx.update(AppState.clearCompleted),
            },
        }));
    }
};

// =============================================================================
// Tests — the whole model is exercised with zero UI in play.
// =============================================================================

test "add trims, ignores blanks, and respects capacity" {
    var s = AppState{};

    s.pushTodo("  buy milk  ");
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqualStrings("buy milk", s.todos[0].text());

    s.pushTodo("   "); // blank after trim -> ignored
    try std.testing.expectEqual(@as(usize, 1), s.count);

    var i: usize = 0;
    while (i < MAX_TODOS + 5) : (i += 1) s.pushTodo("x");
    try std.testing.expectEqual(@as(usize, MAX_TODOS), s.count);
}

test "toggle flips done and is bounds-checked" {
    var s = AppState{};
    s.pushTodo("task");

    s.toggle(0);
    try std.testing.expect(s.todos[0].done);
    s.toggle(0);
    try std.testing.expect(!s.todos[0].done);

    s.toggle(99); // out of range -> no-op, no panic
    try std.testing.expectEqual(@as(usize, 1), s.count);
}

test "remove keeps the list contiguous" {
    var s = AppState{};
    s.pushTodo("a");
    s.pushTodo("b");
    s.pushTodo("c");

    s.remove(1); // drop "b"
    try std.testing.expectEqual(@as(usize, 2), s.count);
    try std.testing.expectEqualStrings("a", s.todos[0].text());
    try std.testing.expectEqualStrings("c", s.todos[1].text());
}

test "remaining and clearCompleted" {
    var s = AppState{};
    s.pushTodo("a");
    s.pushTodo("b");
    s.pushTodo("c");
    s.toggle(0);
    s.toggle(2);

    try std.testing.expectEqual(@as(u32, 1), s.remaining());

    s.clearCompleted();
    try std.testing.expectEqual(@as(usize, 1), s.count);
    try std.testing.expectEqualStrings("b", s.todos[0].text());
    try std.testing.expectEqual(@as(u32, 1), s.remaining());
}

test "filter visibility" {
    var s = AppState{};
    s.pushTodo("a");
    s.pushTodo("b");
    s.toggle(0); // "a" done, "b" active

    s.setFilter(.active);
    try std.testing.expect(!s.visible(&s.todos[0]));
    try std.testing.expect(s.visible(&s.todos[1]));

    s.setFilter(.done);
    try std.testing.expect(s.visible(&s.todos[0]));
    try std.testing.expect(!s.visible(&s.todos[1]));

    s.setFilter(.all);
    try std.testing.expect(s.visible(&s.todos[0]));
    try std.testing.expect(s.visible(&s.todos[1]));
}
