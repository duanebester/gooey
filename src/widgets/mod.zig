//! Widgets - Stateful Widget Implementations
//!
//! Low-level stateful widgets that manage their own internal state
//! (text buffers, cursor positions, scroll offsets, etc.).
//!
//! For most use cases, prefer the high-level components in `gooey.components`:
//!
//! ```zig
//! const gooey = @import("gooey");
//!
//! // Components (preferred — declarative, themed). The user-facing
//! // types `TextInput` / `TextArea` live in `components/`.
//! gooey.TextInput{ .id = "name", .placeholder = "Enter name" }
//! gooey.TextArea{ .id = "bio", .placeholder = "Enter bio" }
//!
//! // Engines (low-level state objects — direct buffer / cursor / IME
//! // access). These are the heap-allocated structs that the framework
//! // retains across frames; their type names carry the `*State` suffix
//! // to disambiguate from the user-facing components.
//! const input: *gooey.widgets.TextInputState = cx.textField("name").?;
//! input.setText("Hello");
//! ```
//!
//! ## Module Organization
//!
//! - `text_input_state` - Single-line text input state management
//! - `text_area_state` - Multi-line text area state management
//! - `text_common` - Shared utilities for text widgets
//! - `scroll_container` - Scrollable container state

const std = @import("std");
const interface_verify = @import("../core/interface_verify.zig");

// =============================================================================
// Text Input (single-line) — engine type
// =============================================================================
//
// `TextInputState` is the engine: heap-allocated state, owned by
// `WidgetStore` (and, after PR 8.4, by `Window.element_states`). The
// user-facing declarative component is `gooey.TextInput` in
// `components/text_input.zig`. The two were merged under a single
// `TextInput` name historically; PR 8.4-prep disambiguates them so
// PR 8.4 can lift the engine onto the keyed pool without a name clash.

pub const text_input_state = @import("text_input_state.zig");

pub const TextInputState = text_input_state.TextInputState;
pub const TextInputBounds = text_input_state.Bounds;
pub const TextInputStyle = text_input_state.Style;

// =============================================================================
// Text Area (multi-line) — engine type
// =============================================================================
//
// Same engine-vs-component split as `TextInputState` above:
// `TextAreaState` is the heap-allocated engine; `gooey.TextArea` in
// `components/text_area.zig` is the user-facing declarative component.

pub const text_area_state = @import("text_area_state.zig");

pub const TextAreaState = text_area_state.TextAreaState;
pub const TextAreaBounds = text_area_state.Bounds;
pub const TextAreaStyle = text_area_state.Style;

// =============================================================================
// Text Common (shared utilities)
// =============================================================================

pub const text_common = @import("text_common.zig");

// =============================================================================
// Edit History (undo/redo for text widgets)
// =============================================================================

pub const edit_history = @import("edit_history.zig");

pub const EditHistory = edit_history.EditHistory;
pub const Edit = edit_history.Edit;
pub const EditOp = edit_history.EditOp;
pub const MAX_HISTORY_SIZE = edit_history.MAX_HISTORY_SIZE;
pub const MAX_EDIT_BYTES = edit_history.MAX_EDIT_BYTES;

// =============================================================================
// Scroll Container
// =============================================================================

pub const scroll_container = @import("scroll_container.zig");

pub const ScrollContainer = scroll_container.ScrollContainer;

// =============================================================================
// Uniform List (Virtualized, fixed-height items)
// =============================================================================

pub const uniform_list = @import("uniform_list.zig");

pub const UniformListState = uniform_list.UniformListState;
pub const VisibleRange = uniform_list.VisibleRange;
pub const ScrollStrategy = uniform_list.ScrollStrategy;
pub const MAX_VISIBLE_ITEMS = uniform_list.MAX_VISIBLE_ITEMS;

// =============================================================================
// Virtual List (Virtualized, variable-height items)
// =============================================================================

pub const virtual_list = @import("virtual_list.zig");

pub const VirtualListState = virtual_list.VirtualListState;

// =============================================================================
// Code Editor (multi-line with line numbers and highlighting)
// =============================================================================

pub const code_editor_state = @import("code_editor_state.zig");

pub const CodeEditorState = code_editor_state.CodeEditorState;
pub const CodeEditorBounds = code_editor_state.Bounds;
pub const CodeEditorStyle = code_editor_state.Style;
pub const HighlightSpan = code_editor_state.HighlightSpan;
pub const MAX_HIGHLIGHT_SPANS = code_editor_state.MAX_HIGHLIGHT_SPANS;
pub const MAX_VIRTUAL_LIST_ITEMS = virtual_list.MAX_VIRTUAL_LIST_ITEMS;
// Note: VirtualList uses its own VisibleRange and ScrollStrategy which are
// compatible with UniformList's versions (same structure)

// =============================================================================
// Data Table (Virtualized 2D table, uniform row height)
// =============================================================================

pub const data_table = @import("data_table.zig");

pub const DataTableState = data_table.DataTableState;
pub const DataTableColumn = data_table.Column;
pub const DataTableSelection = data_table.Selection;
pub const DataTableSelectionMode = data_table.SelectionMode;
pub const SortDirection = data_table.SortDirection;
pub const RowRange = data_table.RowRange;
pub const ColRange = data_table.ColRange;
pub const VisibleRange2D = data_table.VisibleRange2D;
pub const MAX_COLUMNS = data_table.MAX_COLUMNS;
pub const MAX_VISIBLE_ROWS = data_table.MAX_VISIBLE_ROWS;
pub const MAX_VISIBLE_COLUMNS = data_table.MAX_VISIBLE_COLUMNS;

// =============================================================================
// Tree List (Virtualized hierarchical list)
// =============================================================================

pub const tree_list = @import("tree_list.zig");

pub const TreeListState = tree_list.TreeListState;
pub const TreeNode = tree_list.TreeNode;
pub const TreeEntry = tree_list.TreeEntry;
pub const TreeLineChar = tree_list.TreeLineChar;
pub const MAX_TREE_NODES = tree_list.MAX_TREE_NODES;
pub const MAX_VISIBLE_ENTRIES = tree_list.MAX_VISIBLE_ENTRIES;
pub const MAX_TREE_DEPTH = tree_list.MAX_TREE_DEPTH;
pub const MAX_ROOT_NODES = tree_list.MAX_ROOT_NODES;
pub const DEFAULT_INDENT_PX = tree_list.DEFAULT_INDENT_PX;

// =============================================================================
// Compile-time interface checks (PR 4)
// =============================================================================
//
// Pin the `Focusable` trait shape on every focusable widget at the type
// boundary. Per CLAUDE.md §3 and `docs/cleanup-implementation-plan.md` PR 4,
// the failure mode for a missing method must be a compile error here, not a
// silent runtime no-op when the builder skips `withWidget` or the focus
// manager can't drive `blur()`.
//
// Adding a new focusable widget type means: (1) implement `focus`, `blur`,
// `isFocused`, and `focusable` on the widget; (2) add a line below. The
// rest of the framework — `context/`, `ui/`, `cx.zig` — does not need to
// learn about the new type.

comptime {
    interface_verify.verifyFocusableInterface(TextInputState);
    interface_verify.verifyFocusableInterface(TextAreaState);
    interface_verify.verifyFocusableInterface(CodeEditorState);
}

// =============================================================================
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
