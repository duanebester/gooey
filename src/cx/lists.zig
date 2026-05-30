//! `cx.lists` — virtualized list and table widget APIs.
//!
//! This module hosts the bodies of the list-building helpers that used to
//! live directly on `Cx`. They are accessed through the
//! `cx.lists.<name>(...)` sub-namespace, which is implemented as a
//! zero-sized field on `Cx` whose methods recover `*Cx` via
//! `@fieldParentPtr`. That keeps the call shape free of extra parentheses
//! while moving ~400 lines of widget-specific code out of `cx.zig`.
//!
//! ## Why a sub-namespace?
//!
//! `cx.zig` previously held every widget-coordination API at the top
//! level, which crossed the 1,900-line mark and forced unrelated
//! widget plumbing to share the same namespace as core context
//! operations. PR 5 of the cleanup plan groups closely-related calls
//! under explicit sub-namespaces (lists, animations, entities, focus)
//! so each grouping can be read on its own.
//!
//! The original top-level methods (`cx.uniformList`, `cx.treeList`,
//! `cx.virtualList`, `cx.dataTable`) remain as deprecated one-line
//! forwarders into this module — they will be removed in PR 9.

const std = @import("std");

const cx_mod = @import("../cx.zig");
const Cx = cx_mod.Cx;

const ui_mod = @import("../ui/mod.zig");
const UniformListStyle = ui_mod.UniformListStyle;
const VirtualListStyle = ui_mod.VirtualListStyle;
const TreeListStyle = ui_mod.TreeListStyle;
const DataTableStyle = ui_mod.DataTableStyle;

const uniform_list_mod = @import("../widgets/uniform_list.zig");
const UniformListState = uniform_list_mod.UniformListState;

const virtual_list_mod = @import("../widgets/virtual_list.zig");
const VirtualListState = virtual_list_mod.VirtualListState;

const tree_list_mod = @import("../widgets/tree_list.zig");
const TreeListState = tree_list_mod.TreeListState;
const TreeEntry = tree_list_mod.TreeEntry;

const data_table_mod = @import("../widgets/data_table.zig");
const DataTableState = data_table_mod.DataTableState;
const ColRange = data_table_mod.ColRange;

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

    /// Callbacks for data-table rendering. All callbacks receive `*Cx`
    /// for full state and handler access. Mirrors the previous
    /// `Cx.DataTableCallbacks` shape so callers can move with a single
    /// import change.
    pub fn DataTableCallbacks(comptime CxType: type) type {
        return struct {
            /// Render a header cell. Required.
            render_header: *const fn (col: u32, cx: *CxType) void,

            /// Render a data cell. Required.
            render_cell: *const fn (row: u32, col: u32, cx: *CxType) void,

            /// Optional: custom row wrapper for row-level styling /
            /// click handling. If null, the framework renders a
            /// default row container.
            ///
            /// User is responsible for opening the row container,
            /// iterating `visible_cols` to call `render_cell`, and
            /// closing the container.
            render_row: ?*const fn (row: u32, visible_cols: ColRange, cx: *CxType) void = null,
        };
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
    ///         .on_click_handler = cx.updateWith(index, State.selectItem),
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

    // =========================================================================
    // Tree List
    // =========================================================================

    /// Render a virtualized tree list with expandable / collapsible
    /// nodes. The render callback receives the `TreeEntry` and `*Cx`
    /// for full access.
    ///
    /// ```zig
    /// cx.lists.tree("file-tree", &state.tree_state, .{ .grow_height = true }, renderNode);
    /// ```
    pub fn tree(
        self: *Lists,
        id: []const u8,
        tree_state: *TreeListState,
        style: TreeListStyle,
        comptime render_item: fn (entry: *const TreeEntry, cx: *Cx) void,
    ) void {
        std.debug.assert(id.len > 0);

        const c = self.cx();
        const b = c._builder;

        // Rebuild flattened entries if the tree shape changed since the
        // last frame. Cheap when nothing changed.
        if (tree_state.needs_flatten) {
            tree_state.rebuild();
        }

        tree_state.indent_px = style.indent_px;

        // Convert TreeListStyle to UniformListStyle for delegation. Tree
        // lists are uniform-height under the hood; the only added
        // dimension is depth-based indenting handled by callers.
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

        tree_state.list_state.gap_px = style.gap;
        uniform_list_mod.syncScroll(b, id, &tree_state.list_state);

        const params = uniform_list_mod.computeLayout(id, &tree_state.list_state, list_style);

        const content_id = uniform_list_mod.openElements(
            b,
            params,
            list_style,
            tree_state.list_state.scroll_offset_px,
        ) orelse return;

        uniform_list_mod.renderSpacer(b, params.top_spacer_height);

        // Render visible entries with Cx access. Bounds-check the
        // entry index against the flattened entry buffer — the
        // visible range is computed from item_count, but `entries`
        // is the source of truth for what's actually been flattened.
        std.debug.assert(params.range.start <= params.range.end);
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            if (i < tree_state.entry_count) {
                render_item(&tree_state.entries[i], c);
            }
        }

        uniform_list_mod.renderSpacer(b, params.bottom_spacer_height);

        b.layout.closeElement();
        b.layout.closeElement();

        uniform_list_mod.registerScroll(b, id, params, content_id, list_style);
    }

    // =========================================================================
    // Virtual List
    // =========================================================================

    /// Render a virtualized variable-height list.
    ///
    /// The render callback receives `*Cx` for full access to state and
    /// handlers, and must return the actual height of the rendered
    /// item so the list can cache it for scrollbar math.
    ///
    /// ```zig
    /// cx.lists.virtual("my-list", &state.list_state, .{ .grow_height = true }, renderItem);
    ///
    /// fn renderItem(index: u32, cx: *Cx) f32 {
    ///     const s = cx.stateConst(State);
    ///     const item = s.items[index];
    ///     const height: f32 = if (item.expanded) 100.0 else 40.0;
    ///     cx.render(ui.box(.{ .height = height }, .{ ui.text(item.description, .{}) }));
    ///     return height;
    /// }
    /// ```
    pub fn virtual(
        self: *Lists,
        id: []const u8,
        list_state: *VirtualListState,
        style: VirtualListStyle,
        comptime render_item: fn (index: u32, cx: *Cx) f32,
    ) void {
        std.debug.assert(id.len > 0);

        const c = self.cx();
        const b = c._builder;

        list_state.gap_px = style.gap;
        virtual_list_mod.syncScroll(b, id, list_state);

        const params = virtual_list_mod.computeLayout(id, list_state, style);

        const content_id = virtual_list_mod.openElements(
            b,
            params,
            style,
            list_state.scroll_offset_px,
        ) orelse return;

        virtual_list_mod.renderSpacer(b, params.top_spacer_height);

        // Render visible items with Cx access and cache their heights.
        // The returned height is what the next frame's layout uses, so
        // callers must return the height they actually committed to.
        std.debug.assert(params.range.start <= params.range.end);
        var i = params.range.start;
        while (i < params.range.end) : (i += 1) {
            const height = render_item(i, c);
            std.debug.assert(height >= 0.0);
            list_state.setHeight(i, height);
        }

        virtual_list_mod.renderSpacer(b, params.bottom_spacer_height);

        b.layout.closeElement();
        b.layout.closeElement();

        virtual_list_mod.registerScroll(b, id, params, content_id, style);
    }

    // =========================================================================
    // Data Table
    // =========================================================================

    /// Render a virtualized data table.
    ///
    /// `callbacks.render_header` and `callbacks.render_cell` are
    /// required; `callbacks.render_row` is optional and lets callers
    /// take over the row container for row-level click handling and
    /// styling.
    ///
    /// ```zig
    /// cx.lists.dataTable("table", &state.table_state, .{ .grow = true }, .{
    ///     .render_header = renderHeader,
    ///     .render_cell = renderCell,
    /// });
    /// ```
    pub fn dataTable(
        self: *Lists,
        id: []const u8,
        table_state: *DataTableState,
        style: DataTableStyle,
        comptime callbacks: DataTableCallbacks(Cx),
    ) void {
        std.debug.assert(id.len > 0);

        const c = self.cx();
        const b = c._builder;

        // Sync gap and scroll state from style.
        table_state.row_gap_px = style.row_gap;
        data_table_mod.syncScroll(b, id, table_state);

        const params = data_table_mod.computeLayout(id, table_state, style);

        // Open viewport + content. `null` means the table is
        // collapsed to zero size this frame and there's nothing to
        // render — bail out without touching the builder stack.
        const content_id = data_table_mod.openElements(
            b,
            params,
            style,
            table_state.scroll_offset_x,
            table_state.scroll_offset_y,
        ) orelse return;

        // Header row — rendered first so it pins to the top of the
        // viewport regardless of scroll position.
        if (table_state.show_header) {
            data_table_mod.renderHeaderCx(b, table_state, params, style, c, callbacks.render_header);
        }

        if (params.top_spacer > 0) {
            data_table_mod.renderSpacer(b, params.content_width, params.top_spacer);
        }

        // Render visible rows. When the caller provides a custom
        // `render_row`, it is responsible for the row container; the
        // default path delegates to `renderRowCx`.
        const range = params.visible_range;
        std.debug.assert(range.rows.start <= range.rows.end);
        var row = range.rows.start;
        while (row < range.rows.end) : (row += 1) {
            if (callbacks.render_row) |render_row| {
                render_row(row, range.cols, c);
            } else {
                data_table_mod.renderRowCx(
                    b,
                    table_state,
                    row,
                    range.cols,
                    params,
                    style,
                    c,
                    callbacks.render_cell,
                );
            }
        }

        if (params.bottom_spacer > 0) {
            data_table_mod.renderSpacer(b, params.content_width, params.bottom_spacer);
        }

        // Close content container and viewport.
        b.layout.closeElement();
        b.layout.closeElement();

        data_table_mod.registerScroll(b, id, params, content_id, style);
    }
};
