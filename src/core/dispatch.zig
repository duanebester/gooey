//! Dispatch Tree - Event routing through the element hierarchy
//!
//! The dispatch tree mirrors the layout tree and enables:
//! - Hierarchical hit testing (early exit when parent doesn't contain point)
//! - Capture/bubble event propagation
//! - Focus-based keyboard routing
//!
//! ## Architecture
//!
//! During render, elements push/pop dispatch nodes that form a tree mirroring
//! the layout hierarchy. After layout, bounding boxes are synced from the
//! layout engine. Event dispatch then walks this tree for hit testing and
//! propagation.
//!
//! ## Performance
//!
//! - Arena-style reset each frame (no per-node allocations during dispatch)
//! - Flat array storage with index-based parent links (cache-friendly)
//! - Early exit in hit testing when parent bounds don't contain point
//! - Pre-sized path buffers avoid allocations during dispatch

const std = @import("std");
const layout_types = @import("../layout/types.zig");
const focus_mod = @import("focus.zig");
const gooey_mod = @import("gooey.zig");

const BoundingBox = layout_types.BoundingBox;
const FocusId = focus_mod.FocusId;
const Gooey = gooey_mod.Gooey;

// =============================================================================
// Dispatch Node ID
// =============================================================================

/// Lightweight identifier for a dispatch node (index into nodes array)
pub const DispatchNodeId = enum(u32) {
    /// Invalid/null node ID
    invalid = std.math.maxInt(u32),
    _,

    const Self = @This();

    pub fn fromIndex(index: u32) Self {
        return @enumFromInt(index);
    }

    pub fn toIndex(self: Self) ?u32 {
        if (self == .invalid) return null;
        return @intFromEnum(self);
    }

    pub fn isValid(self: Self) bool {
        return self != .invalid;
    }
};

// =============================================================================
// Dispatch Node
// =============================================================================

/// A node in the dispatch tree, corresponding to an element that can
/// receive events or participate in event propagation.
pub const DispatchNode = struct {
    /// Parent node (for building dispatch paths)
    parent: DispatchNodeId = .invalid,

    /// First child node
    first_child: DispatchNodeId = .invalid,

    /// Next sibling node
    next_sibling: DispatchNodeId = .invalid,

    /// Bounding box for hit testing (set after layout)
    bounds: ?BoundingBox = null,

    /// Layout element ID (hash) for linking to layout system
    layout_id: ?u32 = null,

    /// Focus ID if this node is focusable
    focus_id: ?FocusId = null,

    /// Key context for scoped keybindings (e.g., "Editor", "Modal")
    key_context: ?[]const u8 = null,

    /// Number of children (for iteration)
    child_count: u32 = 0,

    // =========================================================================
    // Event Listeners (populated during render)
    // =========================================================================

    /// Simple click handlers (most common case)
    click_listeners: std.ArrayListUnmanaged(ClickListener) = .{},

    /// Click handlers with context (for stateful widgets)
    click_listeners_ctx: std.ArrayListUnmanaged(ClickListenerWithContext) = .{},

    /// Full mouse down listeners with phase control
    mouse_down_listeners: std.ArrayListUnmanaged(MouseListener) = .{},

    /// Key down listeners
    key_down_listeners: std.ArrayListUnmanaged(KeyListener) = .{},

    /// Simple key handlers
    simple_key_listeners: std.ArrayListUnmanaged(SimpleKeyListener) = .{},

    /// Action handlers
    action_listeners: std.ArrayListUnmanaged(ActionListener) = .{},

    /// Click handlers with HandlerRef (new pattern)
    click_listeners_handler: std.ArrayListUnmanaged(ClickListenerHandler) = .{},

    /// Action handlers with HandlerRef (new pattern)
    action_listeners_handler: std.ArrayListUnmanaged(ActionListenerHandler) = .{},

    const Self = @This();

    pub fn containsPoint(self: Self, x: f32, y: f32) bool {
        if (self.bounds) |b| {
            return x >= b.x and x < b.x + b.width and
                y >= b.y and y < b.y + b.height;
        }
        return true;
    }

    /// Clean up listener arrays
    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        self.click_listeners.deinit(allocator);
        self.click_listeners_ctx.deinit(allocator);
        self.key_down_listeners.deinit(allocator);
        self.simple_key_listeners.deinit(allocator);
        self.mouse_down_listeners.deinit(allocator);
        self.action_listeners.deinit(allocator);
        // New handler-based listeners
        self.click_listeners_handler.deinit(allocator);
        self.action_listeners_handler.deinit(allocator);
    }

    /// Reset listeners for reuse (keeps capacity)
    pub fn resetListeners(self: *Self) void {
        self.click_listeners.clearRetainingCapacity();
        self.click_listeners_ctx.clearRetainingCapacity();
        self.mouse_down_listeners.clearRetainingCapacity();
        self.key_down_listeners.clearRetainingCapacity();
        self.simple_key_listeners.clearRetainingCapacity();
        self.action_listeners.clearRetainingCapacity();
        // New handler-based listeners
        self.click_listeners_handler.clearRetainingCapacity();
        self.action_listeners_handler.clearRetainingCapacity();
    }
};

// =============================================================================
// Event Listeners
// =============================================================================

const event_mod = @import("event.zig");
const input_mod = @import("input.zig");

pub const EventPhase = event_mod.EventPhase;
pub const EventResult = event_mod.EventResult;
pub const MouseEvent = input_mod.MouseEvent;
pub const MouseButton = input_mod.MouseButton;

/// Mouse event listener callback
/// Returns EventResult to control propagation
pub const MouseListener = struct {
    /// Callback function pointer
    callback: *const fn (ctx: *anyopaque, event: MouseEvent, phase: EventPhase) EventResult,
    /// User context passed to callback
    context: *anyopaque,
};

/// Simple click handler (no phase/event access needed)
pub const ClickListener = struct {
    callback: *const fn () void,
};

/// Click handler with context (for stateful widgets like checkboxes)
pub const ClickListenerWithContext = struct {
    callback: *const fn (ctx: *anyopaque) void,
    context: *anyopaque,
};

pub const KeyEvent = input_mod.KeyEvent;

/// Key event listener callback
pub const KeyListener = struct {
    callback: *const fn (ctx: *anyopaque, event: KeyEvent, phase: EventPhase) EventResult,
    context: *anyopaque,
};

/// Simple key handler (no context needed)
pub const SimpleKeyListener = struct {
    callback: *const fn (event: KeyEvent) EventResult,
};

const action_mod = @import("action.zig");
pub const ActionTypeId = action_mod.ActionTypeId;
pub const actionTypeId = action_mod.actionTypeId;

const handler_mod = @import("handler.zig");
pub const HandlerRef = handler_mod.HandlerRef;

/// Action listener - handles a specific action type
pub const ActionListener = struct {
    action_type: ActionTypeId,
    callback: *const fn () void,
};

/// Click listener using HandlerRef (new pattern with context)
pub const ClickListenerHandler = struct {
    handler: HandlerRef,
};

/// Action listener using HandlerRef (new pattern with context)
pub const ActionListenerHandler = struct {
    action_type: ActionTypeId,
    handler: HandlerRef,
};

// =============================================================================
// Dispatch Tree
// =============================================================================

/// Tree structure for event dispatch, built during render and used for
/// hit testing and event propagation.
pub const DispatchTree = struct {
    allocator: std.mem.Allocator,

    /// All nodes in the tree (flat array, indices are DispatchNodeId)
    nodes: std.ArrayListUnmanaged(DispatchNode) = .{},

    /// Stack of open nodes during tree construction
    node_stack: std.ArrayListUnmanaged(DispatchNodeId) = .{},

    /// Map from layout ID to dispatch node (for syncing bounds)
    layout_to_node: std.AutoHashMapUnmanaged(u32, DispatchNodeId) = .{},

    /// Map from focus ID hash to dispatch node (for keyboard routing)
    focus_to_node: std.AutoHashMapUnmanaged(u64, DispatchNodeId) = .{},

    /// Root node ID
    root: DispatchNodeId = .invalid,

    const Self = @This();

    /// Maximum depth for dispatch paths (should be plenty for any UI)
    pub const MAX_PATH_DEPTH = 64;

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.nodes.deinit(self.allocator);
        self.node_stack.deinit(self.allocator);
        self.layout_to_node.deinit(self.allocator);
        self.focus_to_node.deinit(self.allocator);
    }

    /// Reset tree for a new frame. Clears all nodes but retains capacity.
    pub fn reset(self: *Self) void {
        // Clear listeners from all nodes (but keep node capacity)
        for (self.nodes.items) |*node| {
            node.resetListeners();
        }

        self.nodes.clearRetainingCapacity();
        self.node_stack.clearRetainingCapacity();
        self.layout_to_node.clearRetainingCapacity();
        self.focus_to_node.clearRetainingCapacity();
        self.root = .invalid;
    }

    // =========================================================================
    // Tree Construction (called during render)
    // =========================================================================

    /// Push a new node onto the tree. Call at element open.
    /// Returns the new node's ID.
    pub fn pushNode(self: *Self) DispatchNodeId {
        const parent_id = self.currentNode();

        // Create new node
        const node_index: u32 = @intCast(self.nodes.items.len);
        const node_id = DispatchNodeId.fromIndex(node_index);

        self.nodes.append(self.allocator, .{
            .parent = parent_id,
        }) catch return .invalid;

        // Link to parent
        if (parent_id.toIndex()) |parent_idx| {
            const parent = &self.nodes.items[parent_idx];
            if (parent.first_child == .invalid) {
                parent.first_child = node_id;
            } else {
                // Find last child and add as sibling
                var last_child = parent.first_child;
                while (self.nodes.items[@intFromEnum(last_child)].next_sibling.isValid()) {
                    last_child = self.nodes.items[@intFromEnum(last_child)].next_sibling;
                }
                self.nodes.items[@intFromEnum(last_child)].next_sibling = node_id;
            }
            parent.child_count += 1;
        } else {
            // This is the root node
            self.root = node_id;
        }

        // Push onto stack
        self.node_stack.append(self.allocator, node_id) catch {};

        return node_id;
    }

    /// Pop current node from the stack. Call at element close.
    pub fn popNode(self: *Self) void {
        if (self.node_stack.items.len > 0) {
            _ = self.node_stack.pop();
        }
    }

    /// Get the current node being built (top of stack)
    pub fn currentNode(self: *const Self) DispatchNodeId {
        if (self.node_stack.items.len == 0) return .invalid;
        return self.node_stack.items[self.node_stack.items.len - 1];
    }

    /// Get mutable reference to a node
    pub fn getNode(self: *Self, id: DispatchNodeId) ?*DispatchNode {
        const index = id.toIndex() orelse return null;
        if (index >= self.nodes.items.len) return null;
        return &self.nodes.items[index];
    }

    /// Get const reference to a node
    pub fn getNodeConst(self: *const Self, id: DispatchNodeId) ?*const DispatchNode {
        const index = id.toIndex() orelse return null;
        if (index >= self.nodes.items.len) return null;
        return &self.nodes.items[index];
    }

    // =========================================================================
    // Node Configuration (called during render)
    // =========================================================================

    /// Associate current node with a layout element ID
    pub fn setLayoutId(self: *Self, layout_id: u32) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.layout_id = layout_id;
            self.layout_to_node.put(self.allocator, layout_id, node_id) catch {};
        }
    }

    /// Register current node as focusable
    pub fn setFocusable(self: *Self, focus_id: FocusId) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.focus_id = focus_id;
            self.focus_to_node.put(self.allocator, focus_id.hash, node_id) catch {};
        }
    }

    /// Set key context for current node (for scoped keybindings)
    pub fn setKeyContext(self: *Self, context: []const u8) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.key_context = context;
        }
    }

    // =========================================================================
    // Bounds Sync (called after layout)
    // =========================================================================

    /// Sync bounds from layout engine to dispatch nodes.
    /// Call this after layout computation is complete.
    pub fn syncBoundsFromLayout(
        self: *Self,
        getBoundingBox: *const fn (u32) ?BoundingBox,
    ) void {
        for (self.nodes.items) |*node| {
            if (node.layout_id) |layout_id| {
                node.bounds = getBoundingBox(layout_id);
            }
        }
    }

    /// Set bounds directly for a specific node
    pub fn setBounds(self: *Self, node_id: DispatchNodeId, bounds: BoundingBox) void {
        if (self.getNode(node_id)) |node| {
            node.bounds = bounds;
        }
    }

    // =========================================================================
    // Hit Testing
    // =========================================================================

    /// Find the deepest node containing the given point.
    /// Returns null if no node contains the point.
    pub fn hitTest(self: *const Self, x: f32, y: f32) ?DispatchNodeId {
        if (!self.root.isValid()) return null;

        var result: ?DispatchNodeId = null;
        self.hitTestRecursive(self.root, x, y, &result);
        return result;
    }

    fn hitTestRecursive(
        self: *const Self,
        node_id: DispatchNodeId,
        x: f32,
        y: f32,
        result: *?DispatchNodeId,
    ) void {
        const node = self.getNodeConst(node_id) orelse return;

        // Early exit if this node has bounds and doesn't contain point
        if (node.bounds) |bounds| {
            if (x < bounds.x or x >= bounds.x + bounds.width or
                y < bounds.y or y >= bounds.y + bounds.height)
            {
                return; // Point not in this subtree
            }
        }

        // This node contains the point (or has no bounds)
        result.* = node_id;

        // Check children (later children are rendered on top, so check all)
        var child = node.first_child;
        while (child.isValid()) {
            self.hitTestRecursive(child, x, y, result);
            const child_node = self.getNodeConst(child) orelse break;
            child = child_node.next_sibling;
        }
    }

    // =========================================================================
    // Dispatch Path
    // =========================================================================

    /// Build the path from root to target node.
    /// Returns a slice into the provided buffer.
    pub fn dispatchPath(
        self: *const Self,
        target: DispatchNodeId,
        buf: *[MAX_PATH_DEPTH]DispatchNodeId,
    ) []DispatchNodeId {
        // Walk from target to root
        var count: usize = 0;
        var current = target;

        while (current.isValid() and count < MAX_PATH_DEPTH) {
            buf[count] = current;
            count += 1;

            const node = self.getNodeConst(current) orelse break;
            current = node.parent;
        }

        // Reverse to get root -> target order
        std.mem.reverse(DispatchNodeId, buf[0..count]);
        return buf[0..count];
    }

    /// Get dispatch path for a focused element
    pub fn focusPath(
        self: *const Self,
        focus_id: FocusId,
        buf: *[MAX_PATH_DEPTH]DispatchNodeId,
    ) ?[]DispatchNodeId {
        const node_id = self.focus_to_node.get(focus_id.hash) orelse return null;
        return self.dispatchPath(node_id, buf);
    }

    /// Get dispatch path from root (for global action dispatch when nothing focused)
    pub fn rootPath(self: *const Self, buf: *[MAX_PATH_DEPTH]DispatchNodeId) ?[]DispatchNodeId {
        if (!self.root.isValid()) return null;
        // Just return the root node - global handlers should be registered there
        buf[0] = self.root;
        return buf[0..1];
    }

    // =========================================================================
    // Debug / Stats
    // =========================================================================

    pub fn nodeCount(self: *const Self) usize {
        return self.nodes.items.len;
    }

    pub fn maxDepth(self: *const Self) u32 {
        if (!self.root.isValid()) return 0;
        return self.computeDepth(self.root);
    }

    fn computeDepth(self: *const Self, node_id: DispatchNodeId) u32 {
        const node = self.getNodeConst(node_id) orelse return 0;

        var max_child_depth: u32 = 0;
        var child = node.first_child;
        while (child.isValid()) {
            const child_depth = self.computeDepth(child);
            max_child_depth = @max(max_child_depth, child_depth);
            const child_node = self.getNodeConst(child) orelse break;
            child = child_node.next_sibling;
        }

        return 1 + max_child_depth;
    }

    // =========================================================================
    // Listener Registration (called during render)
    // =========================================================================

    /// Register a simple click handler on the current node
    pub fn onClick(self: *Self, callback: *const fn () void) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.click_listeners.append(self.allocator, .{
                .callback = callback,
            }) catch {};
        }
    }

    /// Register a click handler using HandlerRef (new pattern)
    pub fn onClickHandler(self: *Self, ref: HandlerRef) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.click_listeners_handler.append(self.allocator, .{
                .handler = ref,
            }) catch {};
        }
    }

    /// Register a click handler with context on the current node
    pub fn onClickWithContext(self: *Self, callback: *const fn (ctx: *anyopaque) void, context: *anyopaque) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.click_listeners_ctx.append(self.allocator, .{
                .callback = callback,
                .context = context,
            }) catch {};
        }
    }

    /// Register a full mouse down listener with phase control
    pub fn onMouseDown(self: *Self, listener: MouseListener) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.mouse_down_listeners.append(self.allocator, listener) catch {};
        }
    }

    // =========================================================================
    // Event Dispatch
    // =========================================================================

    /// Dispatch a click event to the target node and its ancestors (bubble only)
    /// Returns true if any handler consumed the event
    pub fn dispatchClick(self: *Self, target: DispatchNodeId, gooey: *Gooey) bool {
        var path_buf: [MAX_PATH_DEPTH]DispatchNodeId = undefined;
        const path = self.dispatchPath(target, &path_buf);

        // Bubble phase: target -> root
        var i = path.len;
        while (i > 0) {
            i -= 1;
            const node = self.getNodeConst(path[i]) orelse continue;

            // Call simple click listeners (legacy)
            for (node.click_listeners.items) |listener| {
                listener.callback();
                return true;
            }

            // Call context click listeners (legacy)
            for (node.click_listeners_ctx.items) |listener| {
                listener.callback(listener.context);
                return true;
            }

            // Call handler-based click listeners (new pattern)
            for (node.click_listeners_handler.items) |listener| {
                listener.handler.invoke(gooey);
                return true;
            }
        }

        return false;
    }

    /// Dispatch a mouse down event with full capture/bubble phases
    /// Returns true if any handler stopped propagation
    pub fn dispatchMouseDown(self: *Self, target: DispatchNodeId, event: MouseEvent) bool {
        var path_buf: [MAX_PATH_DEPTH]DispatchNodeId = undefined;
        const path = self.dispatchPath(target, &path_buf);

        // Capture phase: root -> target
        for (path) |node_id| {
            const node = self.getNodeConst(node_id) orelse continue;
            for (node.mouse_down_listeners.items) |listener| {
                const result = listener.callback(listener.context, event, .capture);
                if (result == .stop) return true;
            }
        }

        // Bubble phase: target -> root
        var i = path.len;
        while (i > 0) {
            i -= 1;
            const node = self.getNodeConst(path[i]) orelse continue;

            const phase: EventPhase = if (i == path.len - 1) .target else .bubble;

            for (node.mouse_down_listeners.items) |listener| {
                const result = listener.callback(listener.context, event, phase);
                if (result == .stop) return true;
            }
        }

        return false;
    }

    /// Register a key down listener on the current node
    pub fn onKeyDown(self: *Self, listener: KeyListener) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.key_down_listeners.append(self.allocator, listener) catch {};
        }
    }

    /// Register a simple key handler on the current node
    pub fn onKey(self: *Self, callback: *const fn (event: KeyEvent) EventResult) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.simple_key_listeners.append(self.allocator, .{
                .callback = callback,
            }) catch {};
        }
    }

    /// Dispatch a key event through the focus path
    /// Returns true if any handler consumed the event
    pub fn dispatchKeyDown(self: *Self, focus_id: FocusId, event: KeyEvent) bool {
        var path_buf: [MAX_PATH_DEPTH]DispatchNodeId = undefined;
        const path = self.focusPath(focus_id, &path_buf) orelse return false;

        // Capture phase: root -> focused
        for (path) |node_id| {
            const node = self.getNodeConst(node_id) orelse continue;

            for (node.key_down_listeners.items) |listener| {
                const result = listener.callback(listener.context, event, .capture);
                if (result == .stop) return true;
            }
        }

        // Bubble phase: focused -> root
        var i = path.len;
        while (i > 0) {
            i -= 1;
            const node = self.getNodeConst(path[i]) orelse continue;

            const phase: EventPhase = if (i == path.len - 1) .target else .bubble;

            // Full listeners
            for (node.key_down_listeners.items) |listener| {
                const result = listener.callback(listener.context, event, phase);
                if (result == .stop) return true;
            }

            // Simple listeners (bubble phase only)
            if (phase != .capture) {
                for (node.simple_key_listeners.items) |listener| {
                    const result = listener.callback(event);
                    if (result == .stop) return true;
                }
            }
        }

        return false;
    }

    /// Register an action handler on the current node
    pub fn onAction(self: *Self, comptime Action: type, callback: *const fn () void) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.action_listeners.append(self.allocator, .{
                .action_type = actionTypeId(Action),
                .callback = callback,
            }) catch {};
        }
    }

    /// Register an action handler using HandlerRef (new pattern)
    pub fn onActionHandler(self: *Self, comptime Action: type, ref: HandlerRef) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.action_listeners_handler.append(self.allocator, .{
                .action_type = actionTypeId(Action),
                .handler = ref,
            }) catch {};
        }
    }

    /// Build the context stack from a dispatch path
    pub fn contextStack(
        self: *const Self,
        path: []const DispatchNodeId,
        buf: *[MAX_PATH_DEPTH][]const u8,
    ) [][]const u8 {
        var count: usize = 0;
        for (path) |node_id| {
            const node = self.getNodeConst(node_id) orelse continue;
            if (node.key_context) |ctx| {
                if (count < MAX_PATH_DEPTH) {
                    buf[count] = ctx;
                    count += 1;
                }
            }
        }
        return buf[0..count];
    }

    /// Dispatch an action through the focus path
    /// Returns true if a handler was found and called
    pub fn dispatchAction(self: *Self, action_type: ActionTypeId, path: []const DispatchNodeId, gooey: *Gooey) bool {
        // Walk from target to root looking for a handler
        var i = path.len;
        while (i > 0) {
            i -= 1;
            const node = self.getNodeConst(path[i]) orelse continue;

            // Check legacy action listeners
            for (node.action_listeners.items) |listener| {
                if (listener.action_type == action_type) {
                    listener.callback();
                    return true;
                }
            }

            // Check handler-based action listeners (new pattern)
            for (node.action_listeners_handler.items) |listener| {
                if (listener.action_type == action_type) {
                    listener.handler.invoke(gooey);
                    return true;
                }
            }
        }
        return false;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "DispatchNodeId basics" {
    const id = DispatchNodeId.fromIndex(42);
    try std.testing.expect(id.isValid());
    try std.testing.expectEqual(@as(u32, 42), id.toIndex().?);

    try std.testing.expect(!DispatchNodeId.invalid.isValid());
    try std.testing.expectEqual(@as(?u32, null), DispatchNodeId.invalid.toIndex());
}

test "DispatchTree construction" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Build a simple tree: root -> (child1, child2 -> grandchild)
    const root = tree.pushNode();
    tree.setLayoutId(100);

    const child1 = tree.pushNode();
    tree.setLayoutId(101);
    _ = child1;
    tree.popNode();

    const child2 = tree.pushNode();
    tree.setLayoutId(102);

    const grandchild = tree.pushNode();
    tree.setLayoutId(103);
    tree.popNode();

    tree.popNode();
    tree.popNode();

    try std.testing.expectEqual(@as(usize, 4), tree.nodeCount());
    try std.testing.expectEqual(root, tree.root);

    // Check parent links
    const root_node = tree.getNodeConst(root).?;
    try std.testing.expectEqual(DispatchNodeId.invalid, root_node.parent);
    try std.testing.expectEqual(@as(u32, 2), root_node.child_count);

    const child2_node = tree.getNodeConst(child2).?;
    try std.testing.expectEqual(root, child2_node.parent);
    try std.testing.expectEqual(@as(u32, 1), child2_node.child_count);

    const grandchild_node = tree.getNodeConst(grandchild).?;
    try std.testing.expectEqual(child2, grandchild_node.parent);
}

test "DispatchTree hit testing" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Build tree with bounds
    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 100, .height = 100 });

    const child = tree.pushNode();
    tree.setBounds(child, .{ .x = 10, .y = 10, .width = 30, .height = 30 });
    tree.popNode();

    tree.popNode();

    // Hit test inside child
    const hit1 = tree.hitTest(20, 20);
    try std.testing.expectEqual(child, hit1.?);

    // Hit test outside child but inside root
    const hit2 = tree.hitTest(80, 80);
    try std.testing.expectEqual(root, hit2.?);

    // Hit test outside root
    const hit3 = tree.hitTest(150, 150);
    try std.testing.expectEqual(@as(?DispatchNodeId, null), hit3);
}

test "DispatchTree dispatch path" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const root = tree.pushNode();
    const child = tree.pushNode();
    const grandchild = tree.pushNode();
    tree.popNode();
    tree.popNode();
    tree.popNode();

    var buf: [DispatchTree.MAX_PATH_DEPTH]DispatchNodeId = undefined;
    const path = tree.dispatchPath(grandchild, &buf);

    try std.testing.expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqual(root, path[0]);
    try std.testing.expectEqual(child, path[1]);
    try std.testing.expectEqual(grandchild, path[2]);
}

test "DispatchTree focus path" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const focus_id = FocusId.init("my_input");

    _ = tree.pushNode();
    const focusable = tree.pushNode();
    tree.setFocusable(focus_id);
    tree.popNode();
    tree.popNode();

    var buf: [DispatchTree.MAX_PATH_DEPTH]DispatchNodeId = undefined;
    const path = tree.focusPath(focus_id, &buf);

    try std.testing.expect(path != null);
    try std.testing.expectEqual(@as(usize, 2), path.?.len);
    try std.testing.expectEqual(focusable, path.?[1]);
}

test "DispatchTree reset" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    _ = tree.pushNode();
    _ = tree.pushNode();
    tree.popNode();
    tree.popNode();

    try std.testing.expectEqual(@as(usize, 2), tree.nodeCount());

    tree.reset();

    try std.testing.expectEqual(@as(usize, 0), tree.nodeCount());
    try std.testing.expect(!tree.root.isValid());
}
