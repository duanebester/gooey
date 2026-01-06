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
//! // Components (preferred - declarative, themed)
//! gooey.TextInput{ .id = "name", .placeholder = "Enter name" }
//! gooey.TextArea{ .id = "bio", .placeholder = "Enter bio" }
//!
//! // Widgets (low-level - direct state access)
//! const input = cx.textField("name");
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

// =============================================================================
// Text Input (single-line)
// =============================================================================

pub const text_input_state = @import("text_input_state.zig");

pub const TextInput = text_input_state.TextInput;
pub const TextInputBounds = text_input_state.Bounds;
pub const TextInputStyle = text_input_state.Style;

// =============================================================================
// Text Area (multi-line)
// =============================================================================

pub const text_area_state = @import("text_area_state.zig");

pub const TextArea = text_area_state.TextArea;
pub const TextAreaBounds = text_area_state.Bounds;
pub const TextAreaStyle = text_area_state.Style;

// =============================================================================
// Text Common (shared utilities)
// =============================================================================

pub const text_common = @import("text_common.zig");

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
// Tests
// =============================================================================

test {
    std.testing.refAllDecls(@This());
}
