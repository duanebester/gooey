//! `cx.focus` — focus management.
//!
//! This module hosts the bodies of the focus-related helpers that
//! used to live directly on `Cx`. They are accessed through the
//! `cx.focus.<name>(...)` sub-namespace, which is implemented as a
//! zero-sized field on `Cx` whose methods recover `*Cx` via
//! `@fieldParentPtr`. See `lists.zig` for the rationale.
//!
//! ## Naming inside the namespace
//!
//! The redundant `focus` / `Focused` prefix is dropped now that the
//! namespace carries the grouping. `focusTextField` and
//! `focusTextArea` collapse onto a single `widget(id)` call because
//! both routed through `Gooey.focusWidget` already (the per-type
//! distinction was vestigial after PR 4 broke the backward edges).
//!
//! | Old                          | New                              |
//! | ---------------------------- | -------------------------------- |
//! | `cx.focusNext()`             | `cx.focus.next()`                |
//! | `cx.focusPrev()`             | `cx.focus.prev()`                |
//! | `cx.blurAll()`               | `cx.focus.blurAll()`             |
//! | `cx.focusTextField(id)`      | `cx.focus.widget(id)`            |
//! | `cx.focusTextArea(id)`       | `cx.focus.widget(id)`            |
//! | `cx.isElementFocused(id)`    | `cx.focus.isElementFocused(id)`  |
//!
//! The original top-level methods remain as deprecated one-line
//! forwarders into this module — they will be removed in PR 9.

const std = @import("std");

const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;

/// Zero-sized namespace marker. Lives as the `focus` field on `Cx`
/// and recovers the parent context via `@fieldParentPtr` from each
/// method. See `lists.zig` for the rationale (CLAUDE.md §10 — don't
/// take aliases).
pub const Focus = struct {
    /// Force this ZST to inherit `Cx`'s alignment via a zero-byte
    /// `[0]usize` filler — see the matching note in `cx/lists.zig`
    /// for the rationale. Without this, the namespace field would
    /// limit `Cx`'s overall alignment to 1 and `@fieldParentPtr`
    /// would fail to compile with "increases pointer alignment".
    _align: [0]usize = .{},

    /// Recover the owning `*Cx` from this namespace field.
    inline fn cx(self: *Focus) *Cx {
        return @fieldParentPtr("focus", self);
    }

    // =========================================================================
    // Tab-order navigation
    // =========================================================================

    /// Move focus to the next focusable element in tab order. The
    /// previously-focused widget receives a `blur` notification first
    /// — that ordering is owned by `Gooey.focusNext`, which fires the
    /// blur handler before flipping the `Focusable` vtable's
    /// `focused` flag.
    pub fn next(self: *Focus) void {
        self.cx()._gooey.focusNext();
    }

    /// Move focus to the previous focusable element in tab order.
    /// Mirrors `next` exactly except for the traversal direction.
    pub fn prev(self: *Focus) void {
        self.cx()._gooey.focusPrev();
    }

    // =========================================================================
    // Direct focus / blur
    // =========================================================================

    /// Remove focus from all elements. The previously-focused widget
    /// receives a `blur` notification through its `Focusable` vtable
    /// — no walk over per-type widget maps required (PR 4).
    pub fn blurAll(self: *Focus) void {
        self.cx()._gooey.blurAll();
    }

    /// Focus a specific widget by string id.
    ///
    /// Replaces the historical `focusTextField` / `focusTextArea`
    /// pair: both routed through `Gooey.focusWidget` already, and the
    /// per-type distinction was vestigial after PR 4 broke the
    /// backward edges from `Gooey` into the widget store. Callers
    /// pass the id they registered the widget with (text input, text
    /// area, code editor, or any other `Focusable`) and the focus
    /// manager dispatches through the trait.
    pub fn widget(self: *Focus, id: []const u8) void {
        std.debug.assert(id.len > 0);
        self.cx()._gooey.focusWidget(id);
    }

    // =========================================================================
    // Queries
    // =========================================================================

    /// Returns `true` if the element with the given id currently
    /// holds focus. The lookup goes through `FocusManager` rather
    /// than scanning the dispatch tree, so it stays O(1) regardless
    /// of element count.
    pub fn isElementFocused(self: *Focus, id: []const u8) bool {
        std.debug.assert(id.len > 0);
        return self.cx()._gooey.isElementFocused(id);
    }
};
