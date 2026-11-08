//! `cx.lists` — the virtualized uniform list widget API.
//!
//! This module hosts the bodies of the list-building helpers. They are
//! accessed through the `cx.lists.<name>(...)` sub-namespace, which is
//! implemented as a zero-sized field on `Cx` whose methods recover `*Cx`
//! via `@fieldParentPtr`. That keeps the call shape free of extra
//! parentheses while keeping ~400 lines of widget-specific code out of
//! `cx.zig`.
//!
//! ## Why a sub-namespace?
//!
//! Holding every widget-coordination API at the top level of `cx.zig`
//! would push it past 1,900 lines and force unrelated widget plumbing
//! to share the same namespace as core context operations. Grouping
//! closely-related calls under explicit sub-namespaces (lists,
//! animations, entities, focus) lets each grouping be read on its own.

const std = @import("std");

const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;

const ui_mod = @import("../ui/mod.zig");
const UniformListStyle = ui_mod.UniformListStyle;

const uniform_list_mod = @import("../widgets/uniform_list.zig");
const UniformListState = uniform_list_mod.UniformListState;

/// Zero-sized namespace marker. Lives as the `lists` field on `Cx` and
/// recovers the parent context via `@fieldParentPtr` from each method.
///
/// Storing a real pointer here would duplicate `*Cx` and risk it
/// drifting out of sync with the field that actually owns it (CLAUDE.md
/// §10 — don't take aliases). The zero-sized field keeps `Cx`'s layout
/// unchanged.
pub const Lists = struct {
    /// Force this ZST to inherit the alignment of `Cx`'s largest
    /// field (currently 8 — `*const std.mem.Allocator.VTable`). A
    /// `[0]usize` adds zero bytes but bumps the struct's alignment
    /// requirement, which is exactly what `@fieldParentPtr` needs to
    /// recover a `*Cx` without an alignment-increasing cast. Without
    /// this, the namespace field would limit `Cx`'s overall alignment
    /// to 1 and the recovery would fail to compile.
    _align: [0]usize = .{},

    /// Recover the owning `*Cx` from this namespace field. Sound
    /// because `Lists` lives inside `Cx` at a field offset chosen by
    /// the compiler; the `_align` filler above guarantees the
    /// pointer alignment matches `Cx`'s.
    inline fn cx(self: *Lists) *Cx {
        return @fieldParentPtr("lists", self);
    }

    // =========================================================================
    // Uniform List
    // =========================================================================

    /// Render a virtualized uniform-height list.
    ///
    /// The render callback receives `*Cx` for full access to state and
    /// handlers.
    ///
    /// ```zig
    /// cx.lists.uniform("my-list", &state.list_state, .{ .grow_height = true }, renderItem);
    ///
    /// fn renderItem(index: u32, cx: *Cx) void {
    ///     const s = cx.stateConst(State);
    ///     cx.render(ui.box(.{
    ///         .height = 32,
    ///         .on_click = cx.on(State.selectItem, .{ .arg = index }),
    ///     }, .{ ui.text(s.items[index].name, .{}) }));
    /// }
    /// ```
    pub fn uniform(
        self: *Lists,
        id: []const u8,
        list_state: *UniformListState,
        style: UniformListStyle,
        comptime render_item: fn (index: u32, cx: *Cx) void,
    ) void {
        std.debug.assert(id.len > 0);

        const c = self.cx();
        const b = c._builder;

        // Sync gap and scroll state with style + builder.
        list_state.gap_px = style.gap;
        uniform_list_mod.syncScroll(b, id, list_state);

        // Compute layout parameters (visible range, spacers, content size).
        const params = uniform_list_mod.computeLayout(id, list_state, style);

        // Open viewport and content elements.
        const content_id = uniform_list_mod.openElements(
            b,
            params,
            style,
            list_state.scroll_offset_px,
        ) orelse return;

        uniform_list_mod.renderSpacer(b, params.top_spacer_height);

        // Render visible items with Cx access.
        std.debug.assert(params.range.start <= params.range.end);
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            render_item(i, c);
        }

        uniform_list_mod.renderSpacer(b, params.bottom_spacer_height);

        // Close content container and viewport.
        b.layout.closeElement();
        b.layout.closeElement();

        uniform_list_mod.registerScroll(b, id, params, content_id, style);
    }
};
