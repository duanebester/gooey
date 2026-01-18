//! TreeList - Virtualized hierarchical list
//!
//! Renders tree structures efficiently by flattening visible nodes
//! and delegating to UniformListState for virtualization.
//!
//! ## Usage
//!
//! ```zig
//! // In your retained state:
//! var tree_state = TreeListState.init(24.0);
//!
//! // Add nodes (parent index, child count, is_folder)
//! tree_state.addNode(.{ .parent = null, .first_child = 1, .child_count = 2, .is_folder = true });
//! tree_state.addNode(.{ .parent = 0, .first_child = null, .child_count = 0, .is_folder = false });
//! tree_state.addNode(.{ .parent = 0, .first_child = null, .child_count = 0, .is_folder = false });
//!
//! // Set roots and flatten
//! tree_state.setRoots(&[_]u32{0});
//! tree_state.flatten();
//! ```
//!
//! ## Memory: Fixed allocation at init time (per CLAUDE.md)
//! - nodes: MAX_TREE_NODES * @sizeOf(TreeNode) = 8192 * 24 = 192KB
//! - entries: MAX_VISIBLE_ENTRIES * @sizeOf(TreeEntry) = 4096 * 8 = 32KB
//! - expanded: MAX_TREE_NODES / 8 = 1KB bitset
//! - Total: ~225KB per TreeListState

const std = @import("std");
const UniformListState = @import("uniform_list.zig").UniformListState;

// =============================================================================
// Constants (per CLAUDE.md - put a limit on everything)
// =============================================================================

/// Maximum nodes in tree. Prevents unbounded growth.
pub const MAX_TREE_NODES: u32 = 8192;

/// Maximum flattened visible entries. Limits flatten output.
pub const MAX_VISIBLE_ENTRIES: u32 = 4096;

/// Maximum nesting depth. Prevents stack overflow in flatten.
pub const MAX_TREE_DEPTH: u8 = 32;

/// Maximum root nodes. Most trees have 1-10 roots.
pub const MAX_ROOT_NODES: u32 = 256;

/// Default pixels per depth level for indentation.
pub const DEFAULT_INDENT_PX: f32 = 16.0;

// =============================================================================
// Tree Node (user's data reference)
// =============================================================================

/// Reference to a node in the user's tree data.
/// User provides: parent index, child info, is_folder flag.
/// Size: 24 bytes (?u32 = 8 bytes each due to alignment)
pub const TreeNode = struct {
    /// Index of parent node (null for roots)
    parent: ?u32,

    /// Index of first child (null if leaf or empty folder)
    first_child: ?u32,

    /// Number of direct children
    child_count: u32,

    /// Is this a folder/expandable node?
    is_folder: bool,
};

// Compile-time size assertion (per CLAUDE.md)
comptime {
    std.debug.assert(@sizeOf(TreeNode) == 24);
}

// =============================================================================
// Tree Entry (flattened for rendering)
// =============================================================================

/// A visible entry in the flattened tree list.
/// This is what the render callback receives.
/// Size: 12 bytes (4 + 4 + 1 + 1 + 1 + 1)
pub const TreeEntry = struct {
    /// Index into user's node array
    node_index: u32,

    /// Ancestry mask for tree line rendering.
    /// Bit i is set if the ancestor at depth i has a next sibling.
    /// Used to determine which vertical lines to draw at each depth level.
    ancestry_mask: u32,

    /// Depth level (0 = root)
    depth: u8,

    /// Is this a folder?
    is_folder: bool,

    /// Is currently expanded?
    is_expanded: bool,

    /// Does this node have a next sibling? (for tree lines)
    has_next_sibling: bool,

    const Self = @This();

    /// Get the tree line character for a specific depth level.
    /// Returns the appropriate box-drawing character for tree visualization.
    pub fn getTreeLineChar(self: *const Self, depth_level: u8) TreeLineChar {
        // Assertions per CLAUDE.md
        std.debug.assert(depth_level <= self.depth);
        std.debug.assert(depth_level < MAX_TREE_DEPTH);

        if (depth_level == self.depth) {
            // This is the node's own level
            return if (self.has_next_sibling) .branch else .corner;
        } else {
            // This is an ancestor level
            const has_sibling_at_depth = (self.ancestry_mask & (@as(u32, 1) << @intCast(depth_level))) != 0;
            return if (has_sibling_at_depth) .vertical else .space;
        }
    }

    /// Check if ancestor at given depth has a next sibling.
    pub fn hasAncestorSiblingAt(self: *const Self, depth_level: u8) bool {
        std.debug.assert(depth_level < MAX_TREE_DEPTH);
        return (self.ancestry_mask & (@as(u32, 1) << @intCast(depth_level))) != 0;
    }
};

/// Tree line character types for rendering
pub const TreeLineChar = enum {
    /// "├" - Branch: node has siblings after it
    branch,
    /// "└" - Corner: last sibling at this level
    corner,
    /// "│" - Vertical: ancestor has siblings, draw continuation line
    vertical,
    /// " " - Space: no line needed (ancestor was last sibling)
    space,

    /// Get UTF-8 box-drawing character
    pub fn toChar(self: TreeLineChar) []const u8 {
        return switch (self) {
            .branch => "├",
            .corner => "└",
            .vertical => "│",
            .space => " ",
        };
    }

    /// Get horizontal extension for branch/corner
    pub fn toCharWithHorizontal(self: TreeLineChar) []const u8 {
        return switch (self) {
            .branch => "├─",
            .corner => "└─",
            .vertical => "│ ",
            .space => "  ",
        };
    }

    /// Get the icon name for tree line rendering.
    /// Use with Icons.tree_branch, Icons.tree_corner, etc from svg.zig.
    /// Returns null for space (no icon needed).
    pub fn getIconName(self: TreeLineChar) ?[]const u8 {
        return switch (self) {
            .branch => "tree_branch",
            .corner => "tree_corner",
            .vertical => "tree_vertical",
            .space => null,
        };
    }

    /// Check if this line type needs rendering (not a space)
    pub fn needsRender(self: TreeLineChar) bool {
        return self != .space;
    }
};

// Compile-time size assertion (per CLAUDE.md)
comptime {
    std.debug.assert(@sizeOf(TreeEntry) == 12);
}

// =============================================================================
// Tree List State
// =============================================================================

/// Retained state for a virtualized tree list.
/// Store this in your component/view state - do NOT recreate each frame.
pub const TreeListState = struct {
    // -------------------------------------------------------------------------
    // User's tree structure (set once, or when data changes)
    // -------------------------------------------------------------------------

    /// Node definitions from user
    nodes: [MAX_TREE_NODES]TreeNode = undefined,

    /// Current number of nodes
    node_count: u32 = 0,

    /// Root node indices (trees can have multiple roots)
    roots: [MAX_ROOT_NODES]u32 = undefined,

    /// Number of root nodes
    root_count: u32 = 0,

    // -------------------------------------------------------------------------
    // Expansion state
    // -------------------------------------------------------------------------

    /// Bitset tracking which nodes are expanded
    expanded: std.StaticBitSet(MAX_TREE_NODES) = std.StaticBitSet(MAX_TREE_NODES).initEmpty(),

    // -------------------------------------------------------------------------
    // Flattened visible entries (rebuilt on expand/collapse)
    // -------------------------------------------------------------------------

    /// Currently visible entries after flattening
    entries: [MAX_VISIBLE_ENTRIES]TreeEntry = undefined,

    /// Number of visible entries
    entry_count: u32 = 0,

    // -------------------------------------------------------------------------
    // Selection state
    // -------------------------------------------------------------------------

    /// Currently selected entry index (in flattened list)
    selected_index: ?u32 = null,

    // -------------------------------------------------------------------------
    // Underlying virtualization
    // -------------------------------------------------------------------------

    /// Underlying uniform list for virtualization
    list_state: UniformListState,

    /// Indent pixels per depth level
    indent_px: f32 = DEFAULT_INDENT_PX,

    // -------------------------------------------------------------------------
    // Dirty tracking
    // -------------------------------------------------------------------------

    /// Tree structure or expansion changed - needs re-flatten
    needs_flatten: bool = true,

    const Self = @This();

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize with item height for virtualization.
    /// item_height_px must be > 0.
    pub fn init(item_height_px: f32) Self {
        // Assertions per CLAUDE.md (minimum 2 per function)
        std.debug.assert(item_height_px > 0);
        std.debug.assert(item_height_px < 10000); // Sanity upper bound

        return .{
            .list_state = UniformListState.init(0, item_height_px),
        };
    }

    /// Initialize with item height and custom indentation.
    /// item_height_px must be > 0, indent_px must be >= 0.
    pub fn initWithIndent(item_height_px: f32, indent_px: f32) Self {
        std.debug.assert(item_height_px > 0);
        std.debug.assert(indent_px >= 0);

        var self = init(item_height_px);
        self.indent_px = indent_px;
        return self;
    }

    // =========================================================================
    // Node Management
    // =========================================================================

    /// Clear all nodes and reset state.
    pub fn clear(self: *Self) void {
        self.node_count = 0;
        self.root_count = 0;
        self.entry_count = 0;
        self.selected_index = null;
        self.expanded = std.StaticBitSet(MAX_TREE_NODES).initEmpty();
        self.needs_flatten = true;
        self.list_state.setItemCount(0);

        // Assert post-conditions
        std.debug.assert(self.node_count == 0);
        std.debug.assert(self.root_count == 0);
    }

    /// Add a root node. Returns node index.
    /// This is a convenience method that adds a node and registers it as a root.
    pub fn addRoot(self: *Self, is_folder: bool) ?u32 {
        // Assert pre-conditions
        std.debug.assert(self.node_count <= MAX_TREE_NODES);
        std.debug.assert(self.root_count <= MAX_ROOT_NODES);

        const node_idx = self.addNode(.{
            .parent = null,
            .first_child = null,
            .child_count = 0,
            .is_folder = is_folder,
        }) orelse return null;

        if (self.root_count >= MAX_ROOT_NODES) return null;
        self.roots[self.root_count] = node_idx;
        self.root_count += 1;

        // Assert post-conditions
        std.debug.assert(self.root_count > 0);

        return node_idx;
    }

    /// Add a child node to parent. Returns node index.
    /// Children are expected to be added in order (sequential indices).
    pub fn addChild(self: *Self, parent_idx: u32, is_folder: bool) ?u32 {
        // Assert pre-conditions
        std.debug.assert(parent_idx < self.node_count);
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        const node_idx = self.addNode(.{
            .parent = parent_idx,
            .first_child = null,
            .child_count = 0,
            .is_folder = is_folder,
        }) orelse return null;

        // Update parent's child tracking
        var parent = &self.nodes[parent_idx];
        if (parent.first_child == null) {
            parent.first_child = node_idx;
        }
        parent.child_count += 1;

        // Assert post-conditions
        std.debug.assert(parent.child_count > 0);

        return node_idx;
    }

    /// Add a node to the tree. Returns the node index.
    /// Returns null if tree is full.
    /// For most use cases, prefer addRoot() or addChild().
    pub fn addNode(self: *Self, node: TreeNode) ?u32 {
        // Assert pre-conditions
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        if (self.node_count >= MAX_TREE_NODES) {
            return null;
        }

        const index = self.node_count;
        self.nodes[index] = node;
        self.node_count += 1;
        self.needs_flatten = true;

        // Assert post-conditions
        std.debug.assert(self.node_count > 0);

        return index;
    }

    /// Set the root node indices.
    /// Roots are rendered in order at depth 0.
    pub fn setRoots(self: *Self, root_indices: []const u32) void {
        // Assert pre-conditions
        std.debug.assert(root_indices.len <= MAX_ROOT_NODES);

        const count: u32 = @intCast(@min(root_indices.len, MAX_ROOT_NODES));
        for (0..count) |i| {
            const root_idx = root_indices[i];
            // Validate root index is within bounds
            std.debug.assert(root_idx < self.node_count);
            self.roots[i] = root_idx;
        }
        self.root_count = count;
        self.needs_flatten = true;

        // Assert post-conditions
        std.debug.assert(self.root_count == count);
    }

    /// Get a node by index.
    /// Returns null if index is out of bounds.
    pub fn getNode(self: *const Self, index: u32) ?*const TreeNode {
        // Assert pre-conditions
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        if (index >= self.node_count) {
            return null;
        }
        return &self.nodes[index];
    }

    /// Get a mutable node by index.
    /// Returns null if index is out of bounds.
    pub fn getNodeMut(self: *Self, index: u32) ?*TreeNode {
        // Assert pre-conditions
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        if (index >= self.node_count) {
            return null;
        }
        return &self.nodes[index];
    }

    // =========================================================================
    // Expansion State
    // =========================================================================

    /// Check if a node is expanded.
    pub fn isExpanded(self: *const Self, node_index: u32) bool {
        std.debug.assert(node_index < MAX_TREE_NODES);
        std.debug.assert(node_index < self.node_count);

        return self.expanded.isSet(node_index);
    }

    /// Set a node's expanded state.
    pub fn setExpanded(self: *Self, node_index: u32, is_expanded: bool) void {
        std.debug.assert(node_index < MAX_TREE_NODES);
        std.debug.assert(node_index < self.node_count);

        if (is_expanded) {
            self.expanded.set(node_index);
        } else {
            self.expanded.unset(node_index);
        }
        self.needs_flatten = true;
    }

    /// Expand a node by node index (mark for showing children).
    /// Prefer expandEntry() for UI interactions.
    pub fn expandNode(self: *Self, node_index: u32) void {
        self.setExpanded(node_index, true);
    }

    /// Collapse a node by node index (hide children).
    /// Prefer collapseEntry() for UI interactions.
    pub fn collapseNode(self: *Self, node_index: u32) void {
        self.setExpanded(node_index, false);
    }

    /// Expand all nodes.
    pub fn expandAll(self: *Self) void {
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        for (0..self.node_count) |i| {
            if (self.nodes[i].is_folder) {
                self.expanded.set(i);
            }
        }
        self.needs_flatten = true;

        std.debug.assert(self.needs_flatten);
    }

    /// Collapse all nodes.
    pub fn collapseAll(self: *Self) void {
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        self.expanded = std.StaticBitSet(MAX_TREE_NODES).initEmpty();
        self.needs_flatten = true;

        std.debug.assert(self.needs_flatten);
    }

    // =========================================================================
    // Flattening (rebuild visible entries)
    // =========================================================================

    /// Rebuild flattened entries from current expansion state.
    /// Call after changing tree structure or toggling expansion.
    /// This is called automatically by the builder, but can be called
    /// manually if you need immediate access to entries.
    pub fn rebuild(self: *Self) void {
        // Assert pre-conditions
        std.debug.assert(self.node_count <= MAX_TREE_NODES);
        std.debug.assert(self.root_count <= MAX_ROOT_NODES);

        self.entry_count = 0;

        // Process each root (ancestry_mask starts at 0 for roots)
        for (0..self.root_count) |i| {
            const root_idx = self.roots[i];
            const has_next = i + 1 < self.root_count;
            self.flattenNode(root_idx, 0, has_next, 0);
        }

        // Update list state item count
        self.list_state.setItemCount(self.entry_count);

        // Clamp selection if needed
        if (self.selected_index) |sel| {
            if (sel >= self.entry_count) {
                self.selected_index = if (self.entry_count > 0) self.entry_count - 1 else null;
            }
        }

        self.needs_flatten = false;

        // Assert post-conditions
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);
        std.debug.assert(!self.needs_flatten);
    }

    /// Flatten a single node and its visible descendants.
    /// ancestry_mask: Bitset where bit i indicates ancestor at depth i has more siblings.
    fn flattenNode(self: *Self, node_idx: u32, depth: u8, has_next_sibling: bool, ancestry_mask: u32) void {
        // Depth limit check (per CLAUDE.md - put a limit on everything)
        if (depth >= MAX_TREE_DEPTH) return;
        // Capacity check
        if (self.entry_count >= MAX_VISIBLE_ENTRIES) return;

        // Assert pre-conditions
        std.debug.assert(node_idx < self.node_count);

        const node = &self.nodes[node_idx];
        const is_expanded = self.expanded.isSet(node_idx);

        // Add this node as visible entry
        self.entries[self.entry_count] = .{
            .node_index = node_idx,
            .ancestry_mask = ancestry_mask,
            .depth = depth,
            .is_folder = node.is_folder,
            .is_expanded = is_expanded,
            .has_next_sibling = has_next_sibling,
        };
        self.entry_count += 1;

        // If expanded folder with children, add them
        if (node.is_folder and is_expanded and node.first_child != null) {
            // Update ancestry mask for children: set bit at current depth if this node has siblings
            const child_ancestry = if (has_next_sibling)
                ancestry_mask | (@as(u32, 1) << @intCast(depth))
            else
                ancestry_mask;
            self.flattenChildren(node_idx, depth + 1, child_ancestry);
        }
    }

    /// Flatten all children of a parent node.
    /// ancestry_mask: Inherited ancestry information for tree line rendering.
    fn flattenChildren(self: *Self, parent_idx: u32, depth: u8, ancestry_mask: u32) void {
        // Assert pre-conditions
        std.debug.assert(parent_idx < self.node_count);

        const parent = &self.nodes[parent_idx];
        if (parent.first_child == null) return;

        // Children are stored sequentially starting at first_child
        var children_found: u32 = 0;
        var child_idx = parent.first_child.?;

        // Loop limit (per CLAUDE.md - put a limit on everything)
        const max_iterations = @min(parent.child_count, MAX_TREE_NODES);

        while (children_found < max_iterations) : (children_found += 1) {
            if (child_idx >= self.node_count) break;

            // Verify this node is actually a child of parent
            if (self.nodes[child_idx].parent != parent_idx) break;

            const has_next = children_found + 1 < parent.child_count;
            self.flattenNode(child_idx, depth, has_next, ancestry_mask);

            // Move to next sequential node
            child_idx += 1;
        }
    }

    // =========================================================================
    // Entry-Based Expand/Collapse (for UI interactions)
    // =========================================================================

    /// Toggle expansion state of entry at index.
    /// Does nothing if entry is not a folder.
    pub fn toggleExpand(self: *Self, entry_index: u32) void {
        // Assert pre-conditions
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (entry_index >= self.entry_count) return;

        const entry = &self.entries[entry_index];
        if (!entry.is_folder) return;

        self.expanded.toggle(entry.node_index);
        self.rebuild();

        // Assert post-conditions
        std.debug.assert(!self.needs_flatten);
    }

    /// Expand entry at index (shows children).
    /// Does nothing if not a folder or already expanded.
    pub fn expandEntry(self: *Self, entry_index: u32) void {
        // Assert pre-conditions
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (entry_index >= self.entry_count) return;
        const entry = &self.entries[entry_index];
        if (!entry.is_folder or entry.is_expanded) return;

        self.expanded.set(entry.node_index);
        self.rebuild();
    }

    /// Collapse entry at index (hides children).
    /// Does nothing if not a folder or already collapsed.
    pub fn collapseEntry(self: *Self, entry_index: u32) void {
        // Assert pre-conditions
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (entry_index >= self.entry_count) return;
        const entry = &self.entries[entry_index];
        if (!entry.is_folder or !entry.is_expanded) return;

        self.expanded.unset(entry.node_index);
        self.rebuild();
    }

    /// Expand all ancestors of a node to make it visible, then select it.
    pub fn revealNode(self: *Self, node_idx: u32) void {
        // Assert pre-conditions
        std.debug.assert(self.node_count <= MAX_TREE_NODES);

        if (node_idx >= self.node_count) return;

        // Walk up parent chain, expanding each ancestor
        var current = node_idx;
        var iterations: u32 = 0;
        const max_iterations = MAX_TREE_DEPTH; // Limit per CLAUDE.md

        while (iterations < max_iterations) : (iterations += 1) {
            if (self.nodes[current].parent) |parent_idx| {
                self.expanded.set(parent_idx);
                current = parent_idx;
            } else {
                break;
            }
        }
        self.rebuild();

        // Find and select the revealed node
        for (0..self.entry_count) |i| {
            if (self.entries[i].node_index == node_idx) {
                self.selected_index = @intCast(i);
                self.list_state.scrollToItem(@intCast(i), .nearest);
                break;
            }
        }
    }

    // =========================================================================
    // Selection
    // =========================================================================

    /// Select entry at index.
    pub fn selectIndex(self: *Self, index: u32) void {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (index < self.entry_count) {
            self.selected_index = index;
        }
    }

    /// Get the currently selected entry.
    pub fn selectedEntry(self: *const Self) ?*const TreeEntry {
        if (self.selected_index) |idx| {
            if (idx < self.entry_count) {
                return &self.entries[idx];
            }
        }
        return null;
    }

    /// Get the node index of the currently selected entry.
    pub fn selectedNodeIndex(self: *const Self) ?u32 {
        if (self.selectedEntry()) |entry| {
            return entry.node_index;
        }
        return null;
    }

    /// Clear selection.
    pub fn clearSelection(self: *Self) void {
        self.selected_index = null;
    }

    // =========================================================================
    // Keyboard Navigation
    // =========================================================================

    /// Move selection up (previous entry).
    pub fn selectPrevious(self: *Self) void {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (self.entry_count == 0) return;

        if (self.selected_index) |idx| {
            if (idx > 0) {
                self.selected_index = idx - 1;
                self.list_state.scrollToItem(idx - 1, .nearest);
            }
        } else {
            // Nothing selected, select first
            self.selected_index = 0;
        }
    }

    /// Move selection down (next entry).
    pub fn selectNext(self: *Self) void {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (self.entry_count == 0) return;

        if (self.selected_index) |idx| {
            if (idx + 1 < self.entry_count) {
                self.selected_index = idx + 1;
                self.list_state.scrollToItem(idx + 1, .nearest);
            }
        } else {
            // Nothing selected, select first
            self.selected_index = 0;
        }
    }

    /// Left arrow: collapse if expanded folder, else navigate to parent.
    pub fn navigateLeft(self: *Self) void {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        const idx = self.selected_index orelse return;
        if (idx >= self.entry_count) return;

        const entry = &self.entries[idx];

        if (entry.is_folder and entry.is_expanded) {
            // Collapse current folder
            self.collapseEntry(idx);
        } else if (self.nodes[entry.node_index].parent) |parent_node| {
            // Navigate to parent entry
            for (0..self.entry_count) |i| {
                if (self.entries[i].node_index == parent_node) {
                    self.selected_index = @intCast(i);
                    self.list_state.scrollToItem(@intCast(i), .nearest);
                    break;
                }
            }
        }
    }

    /// Right arrow: expand if collapsed folder, else move to first child.
    pub fn navigateRight(self: *Self) void {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        const idx = self.selected_index orelse return;
        if (idx >= self.entry_count) return;

        const entry = &self.entries[idx];
        if (entry.is_folder and !entry.is_expanded) {
            // Expand folder
            self.expandEntry(idx);
        } else if (entry.is_folder and entry.is_expanded and idx + 1 < self.entry_count) {
            // Move to first child (next entry if expanded)
            self.selected_index = idx + 1;
            self.list_state.scrollToItem(idx + 1, .nearest);
        }
    }

    /// Select first entry.
    pub fn selectFirst(self: *Self) void {
        if (self.entry_count > 0) {
            self.selected_index = 0;
            self.list_state.scrollToItem(0, .nearest);
        }
    }

    /// Select last entry.
    pub fn selectLast(self: *Self) void {
        if (self.entry_count > 0) {
            self.selected_index = self.entry_count - 1;
            self.list_state.scrollToItem(self.entry_count - 1, .nearest);
        }
    }

    // =========================================================================
    // Entry Access (for rendering)
    // =========================================================================

    /// Get a visible entry by index.
    /// Returns null if index is out of bounds.
    pub fn getEntry(self: *const Self, index: u32) ?*const TreeEntry {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        if (index >= self.entry_count) {
            return null;
        }
        return &self.entries[index];
    }

    /// Get visible entries slice.
    pub fn getEntries(self: *const Self) []const TreeEntry {
        std.debug.assert(self.entry_count <= MAX_VISIBLE_ENTRIES);

        return self.entries[0..self.entry_count];
    }

    /// Get indentation in pixels for a given depth.
    pub fn indentForDepth(self: *const Self, depth: u8) f32 {
        std.debug.assert(depth <= MAX_TREE_DEPTH);
        std.debug.assert(self.indent_px >= 0);

        return @as(f32, @floatFromInt(depth)) * self.indent_px;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "TreeListState init" {
    const state = TreeListState.init(24.0);

    try std.testing.expectEqual(@as(u32, 0), state.node_count);
    try std.testing.expectEqual(@as(u32, 0), state.root_count);
    try std.testing.expectEqual(@as(u32, 0), state.entry_count);
    try std.testing.expectEqual(@as(?u32, null), state.selected_index);
    try std.testing.expectEqual(DEFAULT_INDENT_PX, state.indent_px);
    try std.testing.expect(state.needs_flatten);
}

test "TreeListState initWithIndent" {
    const state = TreeListState.initWithIndent(24.0, 20.0);

    try std.testing.expectEqual(@as(f32, 20.0), state.indent_px);
}

test "TreeListState addNode" {
    var state = TreeListState.init(24.0);

    const idx = state.addNode(.{
        .parent = null,
        .first_child = null,
        .child_count = 0,
        .is_folder = false,
    });

    try std.testing.expectEqual(@as(?u32, 0), idx);
    try std.testing.expectEqual(@as(u32, 1), state.node_count);
    try std.testing.expect(state.needs_flatten);
}

test "TreeListState setRoots" {
    var state = TreeListState.init(24.0);

    _ = state.addNode(.{ .parent = null, .first_child = null, .child_count = 0, .is_folder = true });
    _ = state.addNode(.{ .parent = null, .first_child = null, .child_count = 0, .is_folder = true });

    state.setRoots(&[_]u32{ 0, 1 });

    try std.testing.expectEqual(@as(u32, 2), state.root_count);
    try std.testing.expectEqual(@as(u32, 0), state.roots[0]);
    try std.testing.expectEqual(@as(u32, 1), state.roots[1]);
}

test "TreeListState clear" {
    var state = TreeListState.init(24.0);

    _ = state.addNode(.{ .parent = null, .first_child = null, .child_count = 0, .is_folder = false });
    state.setRoots(&[_]u32{0});
    state.expandNode(0);

    state.clear();

    try std.testing.expectEqual(@as(u32, 0), state.node_count);
    try std.testing.expectEqual(@as(u32, 0), state.root_count);
    try std.testing.expect(state.needs_flatten);
}

test "TreeListState addRoot" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true);
    try std.testing.expectEqual(@as(?u32, 0), root_idx);
    try std.testing.expectEqual(@as(u32, 1), state.node_count);
    try std.testing.expectEqual(@as(u32, 1), state.root_count);
    try std.testing.expectEqual(@as(u32, 0), state.roots[0]);

    const node = state.getNode(0).?;
    try std.testing.expect(node.is_folder);
    try std.testing.expect(node.parent == null);
}

test "TreeListState addChild" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    const child1_idx = state.addChild(root_idx, false);
    const child2_idx = state.addChild(root_idx, true);

    try std.testing.expectEqual(@as(?u32, 1), child1_idx);
    try std.testing.expectEqual(@as(?u32, 2), child2_idx);
    try std.testing.expectEqual(@as(u32, 3), state.node_count);

    const root = state.getNode(root_idx).?;
    try std.testing.expectEqual(@as(?u32, 1), root.first_child);
    try std.testing.expectEqual(@as(u32, 2), root.child_count);

    const child1 = state.getNode(child1_idx.?).?;
    try std.testing.expectEqual(@as(?u32, 0), child1.parent);
    try std.testing.expect(!child1.is_folder);
}

test "TreeListState rebuild simple" {
    var state = TreeListState.init(24.0);

    // Create: root -> child1, child2
    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);

    // Before expand: only root visible
    state.rebuild();
    try std.testing.expectEqual(@as(u32, 1), state.entry_count);
    try std.testing.expect(!state.needs_flatten);

    const entry0 = state.getEntry(0).?;
    try std.testing.expectEqual(@as(u32, 0), entry0.node_index);
    try std.testing.expectEqual(@as(u8, 0), entry0.depth);
    try std.testing.expect(entry0.is_folder);
    try std.testing.expect(!entry0.is_expanded);
}

test "TreeListState rebuild expanded" {
    var state = TreeListState.init(24.0);

    // Create: root -> child1, child2
    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);

    state.expandNode(root_idx);
    state.rebuild();

    try std.testing.expectEqual(@as(u32, 3), state.entry_count);

    // Check root
    const entry0 = state.getEntry(0).?;
    try std.testing.expectEqual(@as(u32, 0), entry0.node_index);
    try std.testing.expectEqual(@as(u8, 0), entry0.depth);
    try std.testing.expect(entry0.is_expanded);
    try std.testing.expect(!entry0.has_next_sibling);

    // Check child1
    const entry1 = state.getEntry(1).?;
    try std.testing.expectEqual(@as(u32, 1), entry1.node_index);
    try std.testing.expectEqual(@as(u8, 1), entry1.depth);
    try std.testing.expect(entry1.has_next_sibling);

    // Check child2
    const entry2 = state.getEntry(2).?;
    try std.testing.expectEqual(@as(u32, 2), entry2.node_index);
    try std.testing.expectEqual(@as(u8, 1), entry2.depth);
    try std.testing.expect(!entry2.has_next_sibling);
}

test "TreeListState rebuild nested" {
    var state = TreeListState.init(24.0);

    // Create: root -> folder1 -> leaf
    const root_idx = state.addRoot(true).?;
    const folder_idx = state.addChild(root_idx, true).?;
    _ = state.addChild(folder_idx, false);

    state.expandAll();
    state.rebuild();

    try std.testing.expectEqual(@as(u32, 3), state.entry_count);

    // Check depths
    try std.testing.expectEqual(@as(u8, 0), state.getEntry(0).?.depth);
    try std.testing.expectEqual(@as(u8, 1), state.getEntry(1).?.depth);
    try std.testing.expectEqual(@as(u8, 2), state.getEntry(2).?.depth);
}

test "TreeListState rebuild multiple roots" {
    var state = TreeListState.init(24.0);

    const root1 = state.addRoot(false).?;
    const root2 = state.addRoot(true).?;
    _ = state.addChild(root2, false);

    state.expandNode(root2);
    state.rebuild();

    try std.testing.expectEqual(@as(u32, 3), state.entry_count);

    // root1 has next sibling
    try std.testing.expect(state.getEntry(0).?.has_next_sibling);
    try std.testing.expectEqual(root1, state.getEntry(0).?.node_index);

    // root2 has no next sibling
    try std.testing.expect(!state.getEntry(1).?.has_next_sibling);
    try std.testing.expectEqual(root2, state.getEntry(1).?.node_index);
}

test "TreeListState rebuild clamps selection" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);

    state.expandNode(root_idx);
    state.rebuild();
    state.selected_index = 2; // Select last child

    state.collapseNode(root_idx);
    state.rebuild();

    // Selection should be clamped to 0 (only root visible)
    try std.testing.expectEqual(@as(?u32, 0), state.selected_index);
}

test "TreeListState list_state sync" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);

    state.expandNode(root_idx);
    state.rebuild();

    // list_state should have correct item count
    try std.testing.expectEqual(@as(u32, 3), state.list_state.item_count);
}

test "TreeListState toggleExpand" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    state.rebuild();

    try std.testing.expectEqual(@as(u32, 1), state.entry_count);

    // Toggle to expand
    state.toggleExpand(0);
    try std.testing.expectEqual(@as(u32, 2), state.entry_count);
    try std.testing.expect(state.getEntry(0).?.is_expanded);

    // Toggle to collapse
    state.toggleExpand(0);
    try std.testing.expectEqual(@as(u32, 1), state.entry_count);
    try std.testing.expect(!state.getEntry(0).?.is_expanded);
}

test "TreeListState expandEntry/collapseEntry" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    state.rebuild();

    // Expand via entry index
    state.expandEntry(0);
    try std.testing.expectEqual(@as(u32, 2), state.entry_count);

    // Collapse via entry index
    state.collapseEntry(0);
    try std.testing.expectEqual(@as(u32, 1), state.entry_count);

    // Expanding non-folder does nothing
    state.expandEntry(0);
    _ = state.addChild(root_idx, false); // Add a leaf
    state.rebuild();
    state.expandEntry(0); // Expand root
    state.expandEntry(1); // Try to expand leaf - should do nothing
    try std.testing.expectEqual(@as(u32, 3), state.entry_count);
}

test "TreeListState revealNode" {
    var state = TreeListState.init(24.0);

    // Create: root -> folder -> leaf
    const root_idx = state.addRoot(true).?;
    const folder_idx = state.addChild(root_idx, true).?;
    const leaf_idx = state.addChild(folder_idx, false).?;
    state.rebuild();

    // Initially only root visible
    try std.testing.expectEqual(@as(u32, 1), state.entry_count);

    // Reveal the deeply nested leaf
    state.revealNode(leaf_idx);

    // All ancestors expanded, leaf visible and selected
    try std.testing.expectEqual(@as(u32, 3), state.entry_count);
    try std.testing.expectEqual(@as(?u32, 2), state.selected_index);
    try std.testing.expectEqual(leaf_idx, state.selectedNodeIndex().?);
}

test "TreeListState selection methods" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);
    state.expandNode(root_idx);
    state.rebuild();

    try std.testing.expectEqual(@as(?u32, null), state.selected_index);
    try std.testing.expect(state.selectedEntry() == null);

    state.selectIndex(1);
    try std.testing.expectEqual(@as(?u32, 1), state.selected_index);
    try std.testing.expect(state.selectedEntry() != null);
    try std.testing.expectEqual(@as(u32, 1), state.selectedNodeIndex().?);

    state.clearSelection();
    try std.testing.expectEqual(@as(?u32, null), state.selected_index);
}

test "TreeListState selectPrevious/selectNext" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);
    state.expandNode(root_idx);
    state.rebuild();

    // Nothing selected, selectNext selects first
    state.selectNext();
    try std.testing.expectEqual(@as(?u32, 0), state.selected_index);

    // Move down
    state.selectNext();
    try std.testing.expectEqual(@as(?u32, 1), state.selected_index);

    state.selectNext();
    try std.testing.expectEqual(@as(?u32, 2), state.selected_index);

    // At end, can't go further
    state.selectNext();
    try std.testing.expectEqual(@as(?u32, 2), state.selected_index);

    // Move up
    state.selectPrevious();
    try std.testing.expectEqual(@as(?u32, 1), state.selected_index);

    state.selectPrevious();
    try std.testing.expectEqual(@as(?u32, 0), state.selected_index);

    // At start, can't go further
    state.selectPrevious();
    try std.testing.expectEqual(@as(?u32, 0), state.selected_index);
}

test "TreeListState navigateLeft" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    state.expandNode(root_idx);
    state.rebuild();

    // Select child, navigate left goes to parent
    state.selectIndex(1);
    state.navigateLeft();
    try std.testing.expectEqual(@as(?u32, 0), state.selected_index);

    // Root is expanded, navigate left collapses it
    state.navigateLeft();
    try std.testing.expect(!state.getEntry(0).?.is_expanded);
    try std.testing.expectEqual(@as(u32, 1), state.entry_count);
}

test "TreeListState navigateRight" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    state.rebuild();

    // Select collapsed root, navigate right expands it
    state.selectIndex(0);
    state.navigateRight();
    try std.testing.expect(state.getEntry(0).?.is_expanded);
    try std.testing.expectEqual(@as(u32, 2), state.entry_count);

    // Expanded folder, navigate right moves to first child
    state.navigateRight();
    try std.testing.expectEqual(@as(?u32, 1), state.selected_index);
}

test "TreeListState selectFirst/selectLast" {
    var state = TreeListState.init(24.0);

    const root_idx = state.addRoot(true).?;
    _ = state.addChild(root_idx, false);
    _ = state.addChild(root_idx, false);
    state.expandNode(root_idx);
    state.rebuild();

    state.selectLast();
    try std.testing.expectEqual(@as(?u32, 2), state.selected_index);

    state.selectFirst();
    try std.testing.expectEqual(@as(?u32, 0), state.selected_index);
}

test "TreeListState expandNode/collapseNode by node index" {
    var state = TreeListState.init(24.0);

    _ = state.addNode(.{ .parent = null, .first_child = null, .child_count = 2, .is_folder = true });

    try std.testing.expect(!state.isExpanded(0));

    state.expandNode(0);
    try std.testing.expect(state.isExpanded(0));
    try std.testing.expect(state.needs_flatten);

    state.collapseNode(0);
    try std.testing.expect(!state.isExpanded(0));
}

test "TreeListState expandAll/collapseAll" {
    var state = TreeListState.init(24.0);

    _ = state.addNode(.{ .parent = null, .first_child = 1, .child_count = 1, .is_folder = true });
    _ = state.addNode(.{ .parent = 0, .first_child = null, .child_count = 0, .is_folder = true });
    _ = state.addNode(.{ .parent = null, .first_child = null, .child_count = 0, .is_folder = false });

    state.expandAll();
    try std.testing.expect(state.isExpanded(0));
    try std.testing.expect(state.isExpanded(1));
    try std.testing.expect(!state.isExpanded(2)); // Not a folder

    state.collapseAll();
    try std.testing.expect(!state.isExpanded(0));
    try std.testing.expect(!state.isExpanded(1));
}

test "TreeListState getNode" {
    var state = TreeListState.init(24.0);

    _ = state.addNode(.{ .parent = null, .first_child = null, .child_count = 0, .is_folder = true });

    const node = state.getNode(0);
    try std.testing.expect(node != null);
    try std.testing.expect(node.?.is_folder);

    const invalid = state.getNode(999);
    try std.testing.expect(invalid == null);
}

test "TreeListState indentForDepth" {
    const state = TreeListState.init(24.0);

    try std.testing.expectEqual(@as(f32, 0.0), state.indentForDepth(0));
    try std.testing.expectEqual(@as(f32, 16.0), state.indentForDepth(1));
    try std.testing.expectEqual(@as(f32, 32.0), state.indentForDepth(2));
}

test "TreeNode size" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(TreeNode));
}

test "TreeEntry size" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(TreeEntry));
}

test "TreeEntry ancestry_mask simple tree" {
    // Build tree:
    // root (has sibling)
    //   child1
    //   child2
    // root2 (no sibling)
    //   child3
    var state = TreeListState.init(24.0);

    const root1 = state.addRoot(true).?;
    const child1 = state.addChild(root1, false).?;
    _ = child1;
    const child2 = state.addChild(root1, false).?;
    _ = child2;

    const root2 = state.addRoot(true).?;
    const child3 = state.addChild(root2, false).?;
    _ = child3;

    state.expandNode(root1);
    state.expandNode(root2);
    state.rebuild();

    // root1 (depth 0, has next sibling) - ancestry_mask should be 0
    try std.testing.expectEqual(@as(u32, 0), state.entries[0].ancestry_mask);
    try std.testing.expect(state.entries[0].has_next_sibling);

    // child1 (depth 1) - ancestry_mask bit 0 set (root1 has sibling)
    try std.testing.expectEqual(@as(u32, 1), state.entries[1].ancestry_mask);
    try std.testing.expect(state.entries[1].has_next_sibling); // child2 follows

    // child2 (depth 1) - ancestry_mask bit 0 set (root1 has sibling)
    try std.testing.expectEqual(@as(u32, 1), state.entries[2].ancestry_mask);
    try std.testing.expect(!state.entries[2].has_next_sibling); // last child

    // root2 (depth 0, no next sibling) - ancestry_mask should be 0
    try std.testing.expectEqual(@as(u32, 0), state.entries[3].ancestry_mask);
    try std.testing.expect(!state.entries[3].has_next_sibling);

    // child3 (depth 1) - ancestry_mask bit 0 NOT set (root2 has no sibling)
    try std.testing.expectEqual(@as(u32, 0), state.entries[4].ancestry_mask);
}

test "TreeEntry getTreeLineChar" {
    const entry_with_sibling = TreeEntry{
        .node_index = 0,
        .ancestry_mask = 0b01, // ancestor at depth 0 has sibling
        .depth = 1,
        .is_folder = false,
        .is_expanded = false,
        .has_next_sibling = true,
    };

    // At own depth (1), has_next_sibling = true -> branch
    try std.testing.expectEqual(TreeLineChar.branch, entry_with_sibling.getTreeLineChar(1));
    // At depth 0, ancestry_mask bit 0 is set -> vertical
    try std.testing.expectEqual(TreeLineChar.vertical, entry_with_sibling.getTreeLineChar(0));

    const entry_last_sibling = TreeEntry{
        .node_index = 0,
        .ancestry_mask = 0b00, // no ancestors have siblings
        .depth = 1,
        .is_folder = false,
        .is_expanded = false,
        .has_next_sibling = false,
    };

    // At own depth (1), has_next_sibling = false -> corner
    try std.testing.expectEqual(TreeLineChar.corner, entry_last_sibling.getTreeLineChar(1));
    // At depth 0, ancestry_mask bit 0 is NOT set -> space
    try std.testing.expectEqual(TreeLineChar.space, entry_last_sibling.getTreeLineChar(0));
}

test "TreeEntry hasAncestorSiblingAt" {
    const entry = TreeEntry{
        .node_index = 0,
        .ancestry_mask = 0b0101, // bits 0 and 2 set
        .depth = 3,
        .is_folder = false,
        .is_expanded = false,
        .has_next_sibling = false,
    };

    try std.testing.expect(entry.hasAncestorSiblingAt(0));
    try std.testing.expect(!entry.hasAncestorSiblingAt(1));
    try std.testing.expect(entry.hasAncestorSiblingAt(2));
    try std.testing.expect(!entry.hasAncestorSiblingAt(3));
}

test "TreeLineChar toChar" {
    try std.testing.expectEqualStrings("├", TreeLineChar.branch.toChar());
    try std.testing.expectEqualStrings("└", TreeLineChar.corner.toChar());
    try std.testing.expectEqualStrings("│", TreeLineChar.vertical.toChar());
    try std.testing.expectEqualStrings(" ", TreeLineChar.space.toChar());
}

test "TreeLineChar toCharWithHorizontal" {
    try std.testing.expectEqualStrings("├─", TreeLineChar.branch.toCharWithHorizontal());
    try std.testing.expectEqualStrings("└─", TreeLineChar.corner.toCharWithHorizontal());
    try std.testing.expectEqualStrings("│ ", TreeLineChar.vertical.toCharWithHorizontal());
    try std.testing.expectEqualStrings("  ", TreeLineChar.space.toCharWithHorizontal());
}

test "TreeLineChar needsRender" {
    try std.testing.expect(TreeLineChar.branch.needsRender());
    try std.testing.expect(TreeLineChar.corner.needsRender());
    try std.testing.expect(TreeLineChar.vertical.needsRender());
    try std.testing.expect(!TreeLineChar.space.needsRender());
}

test "TreeLineChar getIconName" {
    try std.testing.expectEqualStrings("tree_branch", TreeLineChar.branch.getIconName().?);
    try std.testing.expectEqualStrings("tree_corner", TreeLineChar.corner.getIconName().?);
    try std.testing.expectEqualStrings("tree_vertical", TreeLineChar.vertical.getIconName().?);
    try std.testing.expectEqual(@as(?[]const u8, null), TreeLineChar.space.getIconName());
}
