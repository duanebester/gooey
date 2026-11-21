//! The VOPR's model of the nested_overlay example. The app's state is the
//! Select's and the dialog's, which the model-free invariants already
//! exercise through focus and a11y records, so the model does not predict
//! it. It checks the layer order the example exists for: fragments paint in
//! kind order (popovers before modals) and, within a kind, in open order; a
//! layer opened inside a layer's fragment comes after it; and a modal blocks
//! the pointer to everything before it. When the dialog closes while focus
//! was inside it and no pointer action moved focus, focus lands on a control
//! of the first modal (`checkFocusReturned`). It also counts how far a seed
//! went.

const std = @import("std");
const gooey = @import("gooey");
const nested_overlay = @import("nested_overlay_example");
const vopr = @import("vopr.zig");
const vopr_frame = @import("vopr_frame.zig");

const assert = std.debug.assert;

const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const Action = vopr.Action;

const option_count = nested_overlay.options.len;

pub const NestedOverlayModel = struct {
    /// The rendered frame `observe` last read.
    frame_number_seen: u64,
    menu_shown_last: bool,
    dialog_shown_last: bool,
    /// At the start of every drain since the last build, focus was inside
    /// the dialog of the frame on screen.
    focus_in_dialog: bool,
    /// Pointer actions queued since the last build, which can move focus
    /// anywhere. A drain with a frame in flight builds nothing, so the
    /// build that closes the dialog can come drains after the input.
    pointer_action_count: u32,
    selected_last: ?usize,
    counts: Stats,

    /// The kinds nested_overlay's swarm draws weights for, in this order.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .scroll, .wait_ns, .tick_main, .present, .drag, .resize, .cancel,
    };

    /// The Select's keys and the keys that move focus and click: Tab into
    /// the dialog and Return on Close is the path that closes the dialog
    /// with focus inside it.
    pub const key_choices: []const gooey.input.KeyCode = &.{
        .tab, .@"return", .space, .escape, .up, .down, .home, .end, .a,
    };

    pub const Stats = struct {
        frames: u32,
        menu_frames: u32,
        menu_opens: u32,
        /// Frames whose menu sat above its trigger: the popover flipped.
        menu_flipped_frames: u32,
        /// Frames whose menu reached past the window's right or bottom edge.
        menu_clipped_frames: u32,
        dialog_opens: u32,
        /// Frames with the menu and the dialog both open: two layers opened
        /// from one fragment.
        two_layer_frames: u32,
        /// Dialog closes while focus was inside it, and of those, the ones
        /// after which focus landed on a record of the first modal.
        closes_from_inside: u32,
        focus_returned: u32,
        choices: u32,

        const zero: Stats = .{
            .frames = 0,
            .menu_frames = 0,
            .menu_opens = 0,
            .menu_flipped_frames = 0,
            .menu_clipped_frames = 0,
            .dialog_opens = 0,
            .two_layer_frames = 0,
            .closes_from_inside = 0,
            .focus_returned = 0,
            .choices = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d} frames, {d} with the menu ({d} opens, {d} flipped, " ++
                "{d} past an edge); {d} dialog opens, {d} frames with both layers, " ++
                "{d} closes from inside ({d} returned focus); {d} choices", .{
                self.frames,              self.menu_frames,         self.menu_opens,
                self.menu_flipped_frames, self.menu_clipped_frames, self.dialog_opens,
                self.two_layer_frames,    self.closes_from_inside,  self.focus_returned,
                self.choices,
            });
        }
    };

    pub fn init(self: *NestedOverlayModel) void {
        self.frame_number_seen = 0;
        self.menu_shown_last = false;
        self.dialog_shown_last = false;
        self.focus_in_dialog = true;
        self.pointer_action_count = 0;
        self.selected_last = null;
        self.counts = .zero;
        assert(option_count > 0);
    }

    pub fn stats(self: *const NestedOverlayModel) Stats {
        assert(self.counts.menu_frames <= self.counts.frames);
        return self.counts;
    }

    /// The model keeps no events, so only the queue bounds input.
    pub fn pendingRoom(_: *const NestedOverlayModel) u32 {
        return nested_overlay.App.limits.events.queue_count_max;
    }

    pub fn queue(self: *NestedOverlayModel, action: Action) void {
        assert(action != .tick_main);
        assert(action != .present);
        switch (action) {
            .pointer, .drag => self.pointer_action_count += 1,
            else => {},
        }
    }

    pub fn beginDrain(self: *NestedOverlayModel, window: *Window) void {
        assert(window.phase == .idle);
        const frame = window.rendered();
        self.focus_in_dialog = self.focus_in_dialog and focusInDialog(frame, window.focus);
    }

    pub fn endDrain(self: *NestedOverlayModel, window: *Window, published: bool) void {
        if (published) {
            self.checkFocusReturned(window);
            self.pointer_action_count = 0;
            self.focus_in_dialog = true;
        }
        self.observe(window);
    }

    /// A build that closed the dialog while focus was inside it, with no
    /// pointer action in the drain to move focus elsewhere, leaves focus on
    /// a control of the first modal: the core's `validateFocus` moves a lost
    /// focus to its successor in the frame it built, and the first modal is
    /// the only layer still reachable.
    fn checkFocusReturned(self: *NestedOverlayModel, window: *Window) void {
        if (!self.focus_in_dialog) return;
        if (self.pointer_action_count > 0) return;
        const built = window.built();
        const layers = layersOf(built) orelse return;
        if (layers.dialog != null) return;
        self.counts.closes_from_inside += 1;
        const focused = vopr_frame.findHit(built, window.focus);
        const returned = if (focused) |index| inside(built, index, layers.modal) else false;
        if (!returned) {
            std.debug.panic("vopr nested_overlay: frame {d} closed the dialog with focus " ++
                "inside it, and focus went to {x}, not a control of the modal beneath", .{
                built.frame_number, @backingInt(window.focus),
            });
        }
        self.counts.focus_returned += 1;
    }

    pub fn check(self: *NestedOverlayModel, state: *const nested_overlay.State, step: u64) void {
        _ = step;
        if (state.selected) |index| assert(index < option_count);
        if (!std.meta.eql(state.selected, self.selected_last)) {
            if (state.selected != null) self.counts.choices += 1;
            self.selected_last = state.selected;
        }
    }

    /// Where the generator aims. With the dialog open, its panel, whose
    /// edges sit next to the backdrop that closes it, and a third of the
    /// time the Select's trigger beneath. Else the trigger, and a third of
    /// the time the open menu or, while it is closed, "Open dialog".
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        const layers = layersOf(frame) orelse return null;
        const combobox = nodeIndex(frame, .combobox, 0) orelse return null;
        const trigger = frame.hits[combobox].bounds;
        if (layers.dialog) |dialog| {
            const panel = firstChild(frame, dialog) orelse dialog;
            return .{ .area = frame.hits[panel].bounds, .alternate = trigger };
        }
        const opener = buttonNamed(frame, "Open dialog");
        const alternate = layers.menu orelse opener;
        return .{
            .area = trigger,
            .alternate = if (alternate) |index| frame.hits[index].bounds else null,
        };
    }

    fn observe(self: *NestedOverlayModel, window: *Window) void {
        const frame = window.rendered();
        if (frame.frame_number == self.frame_number_seen) return;
        self.frame_number_seen = frame.frame_number;
        self.counts.frames += 1;
        const layers = layersOf(frame) orelse std.debug.panic(
            "vopr nested_overlay: frame {d} shows no modal",
            .{frame.frame_number},
        );
        checkLayers(window, frame, &layers);
        self.countMenu(window, frame, layers.menu);
        const dialog_shown = layers.dialog != null;
        if (dialog_shown and !self.dialog_shown_last) self.counts.dialog_opens += 1;
        if (dialog_shown and layers.menu != null) self.counts.two_layer_frames += 1;
        self.dialog_shown_last = dialog_shown;
    }

    fn countMenu(
        self: *NestedOverlayModel,
        window: *const Window,
        frame: *const records.Frame,
        listbox: ?u32,
    ) void {
        const shown = listbox != null;
        if (shown and !self.menu_shown_last) self.counts.menu_opens += 1;
        self.menu_shown_last = shown;
        const menu = listbox orelse return;
        self.counts.menu_frames += 1;
        const menu_bounds = frame.hits[menu].bounds;
        const combobox = nodeIndex(frame, .combobox, 0).?;
        if (menu_bounds.y < frame.hits[combobox].bounds.y) self.counts.menu_flipped_frames += 1;
        const right = menu_bounds.x + menu_bounds.width;
        const bottom = menu_bounds.y + menu_bounds.height;
        if (right > window.width or bottom > window.height) self.counts.menu_clipped_frames += 1;
    }
};

fn focusInDialog(frame: *const records.Frame, focus: records.ElementId) bool {
    const layers = layersOf(frame) orelse return false;
    const dialog = layers.dialog orelse return false;
    const focused = vopr_frame.findHit(frame, focus) orelse return false;
    return inside(frame, focused, dialog);
}

/// The records of the frame's layers: the first modal's, the dialog's (the
/// second modal, inside the first), and the menu's.
const Layers = struct { modal: u32, dialog: ?u32, menu: ?u32 };

fn layersOf(frame: *const records.Frame) ?Layers {
    const modal = nodeIndex(frame, .dialog, 0) orelse return null;
    return .{
        .modal = modal,
        .dialog = nodeIndex(frame, .dialog, 1),
        .menu = nodeIndex(frame, .listbox, 0),
    };
}

fn checkLayers(window: *const Window, frame: *const records.Frame, layers: *const Layers) void {
    const top = layers.dialog orelse layers.modal;
    if (frame.modal_hit_start != top) {
        std.debug.panic("vopr nested_overlay: frame {d}: modal_hit_start is {d}, but the " ++
            "topmost modal's record is {d} (first modal {d}, dialog {?d})", .{
            frame.frame_number, frame.modal_hit_start, top, layers.modal, layers.dialog,
        });
    }
    if (layers.dialog) |dialog| {
        checkDialogOnTop(window, frame, dialog, layers.menu);
    } else {
        if (layers.menu) |menu| checkMenuOnTop(window, frame, menu);
    }
}

fn checkDialogOnTop(
    window: *const Window,
    frame: *const records.Frame,
    dialog: u32,
    menu: ?u32,
) void {
    assert(dialog < frame.hit_count);
    var index = dialog;
    while (index < frame.hit_count) : (index += 1) {
        if (!inside(frame, index, dialog)) {
            std.debug.panic("vopr nested_overlay: frame {d}: record {d}, after the dialog's " ++
                "record {d}, is not inside the dialog", .{ frame.frame_number, index, dialog });
        }
        if (frame.hits[index].on_click != records.index_none) {
            checkTopmostAtCentre(window, frame, index);
        }
    }
    const menu_index = menu orelse return;
    const fragment_order = frame.hits[menu_index].fragment < frame.hits[dialog].fragment;
    if (menu_index > dialog or !fragment_order) {
        std.debug.panic("vopr nested_overlay: frame {d}: the menu (record {d}, fragment " ++
            "{d}) is not below the dialog (record {d}, fragment {d})", .{
            frame.frame_number, menu_index,                  frame.hits[menu_index].fragment,
            dialog,             frame.hits[dialog].fragment,
        });
    }
}

fn checkMenuOnTop(window: *const Window, frame: *const records.Frame, menu: u32) void {
    assert(menu < frame.hit_count);
    const panel_last = panelLastIndex(frame, menu);
    var options_seen: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .option) continue;
        options_seen += 1;
        const index = vopr_frame.findHit(frame, node.id) orelse std.debug.panic(
            "vopr nested_overlay: frame {d}: option {x} has no hit record",
            .{ frame.frame_number, @backingInt(node.id) },
        );
        if (index < frame.modal_hit_start or index <= panel_last) {
            std.debug.panic("vopr nested_overlay: frame {d}: option record {d} is not above " ++
                "the modal (modal records from {d}, its panel's last at {d})", .{
                frame.frame_number, index, frame.modal_hit_start, panel_last,
            });
        }
        checkTopmostAtCentre(window, frame, index);
    }
    assert(options_seen == option_count);
}

fn checkTopmostAtCentre(window: *const Window, frame: *const records.Frame, target: u32) void {
    const bounds = frame.hits[target].bounds;
    if (bounds.width == 0 or bounds.height == 0) return;
    const x = bounds.x + bounds.width / 2;
    const y = bounds.y + bounds.height / 2;
    if (x < 0 or y < 0 or x >= window.width or y >= window.height) return;
    const top = vopr_frame.hitIndex(frame, x, y) orelse records.index_none;
    if (top != records.index_none and inside(frame, top, target)) return;
    std.debug.panic("vopr nested_overlay: frame {d}: the topmost record at record {d}'s " ++
        "centre ({d:.1}, {d:.1}) is {d}, which is not inside it", .{
        frame.frame_number, target, x, y, top,
    });
}

/// The last record inside the first modal and outside the menu: the menu,
/// a layer opened inside the modal, must come after all of them.
fn panelLastIndex(frame: *const records.Frame, menu: u32) u32 {
    const modal = nodeIndex(frame, .dialog, 0) orelse return 0;
    var last: u32 = modal;
    var start: u32 = 0;
    while (start < frame.hit_count) : (start += 1) {
        if (inside(frame, start, menu)) continue;
        if (inside(frame, start, modal)) last = @max(last, start);
    }
    assert(last < frame.hit_count);
    return last;
}

fn inside(frame: *const records.Frame, index: u32, root: u32) bool {
    assert(root < frame.hit_count);
    var current = index;
    var depth: u32 = 0;
    while (current != records.index_none) : (depth += 1) {
        assert(depth <= frame.hit_count);
        if (current == root) return true;
        current = frame.hits[current].parent;
    }
    return false;
}

fn firstChild(frame: *const records.Frame, parent: u32) ?u32 {
    assert(parent < frame.hit_count);
    var index = parent + 1;
    while (index < frame.hit_count) : (index += 1) {
        if (frame.hits[index].parent == parent) return index;
    }
    return null;
}

fn buttonNamed(frame: *const records.Frame, name: []const u8) ?u32 {
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != .button) continue;
        const text = frame.text(node.name) orelse continue;
        if (std.mem.eql(u8, text, name)) return vopr_frame.findHit(frame, node.id);
    }
    return null;
}

fn nodeIndex(frame: *const records.Frame, role: anytype, rank: u32) ?u32 {
    var seen: u32 = 0;
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != role) continue;
        if (seen == rank) return vopr_frame.findHit(frame, node.id);
        seen += 1;
    }
    return null;
}
