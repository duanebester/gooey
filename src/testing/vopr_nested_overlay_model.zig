//! The VOPR's model of the nested_overlay example: a modal that stays open,
//! holding a Select whose menu (a popover) opens inside it. The app's state
//! is the Select's, which the model-free invariants already exercise
//! through its focus and a11y records, so the model does not predict it.
//! It checks the layer order the example exists for (contract §6): a layer
//! opened inside a modal comes after the modal's fragment, so the menu
//! paints above the modal and takes the pointer over it.
//!
//! On every newly rendered frame that shows the menu:
//! - every option's hit record is at or after `modal_hit_start`, so the
//!   modal leaves it reachable, and after every record of the modal's
//!   panel, so it is above them;
//! - the topmost record at an option's centre, when the centre is inside
//!   the window, is that option or one of its children.
//! It also counts how far a seed went: menu opens, frames where the menu
//! flipped above its trigger near the window's bottom edge, and choices.

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
    selected_last: ?usize,
    counts: Stats,

    /// The kinds nested_overlay's swarm draws weights for, in this order.
    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .scroll, .wait_ns, .tick_main, .present, .drag, .resize, .cancel,
    };

    pub const Stats = struct {
        frames: u32,
        menu_frames: u32,
        menu_opens: u32,
        /// Frames whose menu sat above its trigger: the popover flipped.
        menu_flipped_frames: u32,
        /// Frames whose menu reached past the window's right or bottom edge.
        menu_clipped_frames: u32,
        choices: u32,

        const zero: Stats = .{
            .frames = 0,
            .menu_frames = 0,
            .menu_opens = 0,
            .menu_flipped_frames = 0,
            .menu_clipped_frames = 0,
            .choices = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d} frames, {d} with the menu ({d} opens, {d} flipped, " ++
                "{d} past an edge); {d} choices", .{
                self.frames,              self.menu_frames,         self.menu_opens,
                self.menu_flipped_frames, self.menu_clipped_frames, self.choices,
            });
        }
    };

    pub fn init(self: *NestedOverlayModel) void {
        self.frame_number_seen = 0;
        self.menu_shown_last = false;
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

    pub fn queue(_: *NestedOverlayModel, action: Action) void {
        assert(action != .tick_main);
        assert(action != .present);
    }

    pub fn beginDrain(_: *NestedOverlayModel, window: *Window) void {
        assert(window.phase == .idle);
    }

    pub fn endDrain(self: *NestedOverlayModel, window: *Window, published: bool) void {
        _ = published;
        self.observe(window);
    }

    pub fn check(self: *NestedOverlayModel, state: *const nested_overlay.State, step: u64) void {
        _ = step;
        if (state.selected) |index| assert(index < option_count);
        if (!std.meta.eql(state.selected, self.selected_last)) {
            if (state.selected != null) self.counts.choices += 1;
            self.selected_last = state.selected;
        }
    }

    /// Where the generator aims: the Select's trigger, and a third of the
    /// time the open menu, or the modal's panel while it is closed, whose
    /// edges sit next to the backdrop.
    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        const combobox = nodeIndex(frame, .combobox) orelse return null;
        const trigger = frame.hits[combobox].bounds;
        const listbox = nodeIndex(frame, .listbox);
        const dialog = nodeIndex(frame, .dialog);
        const alternate = listbox orelse dialog;
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
        const listbox = nodeIndex(frame, .listbox);
        const shown = listbox != null;
        if (shown and !self.menu_shown_last) self.counts.menu_opens += 1;
        self.menu_shown_last = shown;
        if (listbox) |menu| {
            self.counts.menu_frames += 1;
            checkMenuOnTop(window, frame, menu);
            const menu_bounds = frame.hits[menu].bounds;
            const combobox = nodeIndex(frame, .combobox).?;
            if (menu_bounds.y < frame.hits[combobox].bounds.y) self.counts.menu_flipped_frames += 1;
            const right = menu_bounds.x + menu_bounds.width;
            const bottom = menu_bounds.y + menu_bounds.height;
            if (right > window.width or bottom > window.height) {
                self.counts.menu_clipped_frames += 1;
            }
        }
    }
};

/// The layer-order checks on a frame that shows the menu, whose record is
/// at `menu`.
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

/// The topmost record at the option's centre is the option or a child.
fn checkTopmostAtCentre(window: *const Window, frame: *const records.Frame, option: u32) void {
    const bounds = frame.hits[option].bounds;
    if (bounds.width == 0 or bounds.height == 0) return;
    const x = bounds.x + bounds.width / 2;
    const y = bounds.y + bounds.height / 2;
    if (x < 0 or y < 0 or x >= window.width or y >= window.height) return;
    const top = vopr_frame.hitIndex(frame, x, y) orelse records.index_none;
    var index = top;
    var depth: u32 = 0;
    while (index != records.index_none) : (depth += 1) {
        assert(depth <= frame.hit_count);
        if (index == option) return;
        index = frame.hits[index].parent;
    }
    std.debug.panic("vopr nested_overlay: frame {d}: the topmost record at option {d}'s " ++
        "centre ({d:.1}, {d:.1}) is {d}, which is not inside it", .{
        frame.frame_number, option, x, y, top,
    });
}

/// The last record inside the modal's dialog and outside the menu: the
/// menu, a layer opened inside the modal, must come after all of them.
fn panelLastIndex(frame: *const records.Frame, menu: u32) u32 {
    const dialog = nodeIndex(frame, .dialog) orelse return 0;
    var last: u32 = dialog;
    for (0..frame.hit_count) |start| {
        var index: u32 = @intCast(start);
        var depth: u32 = 0;
        const in_dialog = while (index != records.index_none) : (depth += 1) {
            assert(depth <= frame.hit_count);
            if (index == menu) break false;
            if (index == dialog) break true;
            index = frame.hits[index].parent;
        } else false;
        if (in_dialog) last = @max(last, @as(u32, @intCast(start)));
    }
    assert(last < frame.hit_count);
    return last;
}

/// The hit record of the first a11y node with `role`.
fn nodeIndex(frame: *const records.Frame, role: anytype) ?u32 {
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        if (node.role != role) continue;
        return vopr_frame.findHit(frame, node.id);
    }
    return null;
}
