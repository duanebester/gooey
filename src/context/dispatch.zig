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
const drag_mod = @import("drag.zig");

const BoundingBox = layout_types.BoundingBox;
const FocusId = focus_mod.FocusId;
const Gooey = gooey_mod.Gooey;
pub const DragTypeId = drag_mod.DragTypeId;
pub const dragTypeId = drag_mod.dragTypeId;

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

    /// Z-index for layering (higher = on top, used in hit testing)
    z_index: i16 = 0,

    /// Whether this node or any descendant has a floating element
    /// Used for hit testing optimization - can skip subtrees without floating descendants
    has_floating_descendant: bool = false,

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

    /// Click handlers with u32 data (for table column/row clicks)
    click_listeners_data: std.ArrayListUnmanaged(ClickListenerWithData) = .{},

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

    /// Click-outside listeners (for closing dropdowns, modals, etc.)
    click_outside_listeners: std.ArrayListUnmanaged(ClickOutsideListener) = .{},

    // Drag & Drop
    /// Drag source (if this node is draggable)
    drag_source: ?DragSource = null,
    /// Drop target (if this node accepts drops)
    drop_target: ?DropTargetListener = null,

    /// Pointer events mode - when true, this node is transparent to hit testing
    /// (like CSS pointer-events: none)
    pointer_events_none: bool = false,

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
        self.click_listeners_data.deinit(allocator);
        self.key_down_listeners.deinit(allocator);
        self.simple_key_listeners.deinit(allocator);
        self.mouse_down_listeners.deinit(allocator);
        self.action_listeners.deinit(allocator);
        // New handler-based listeners
        self.click_listeners_handler.deinit(allocator);
        self.action_listeners_handler.deinit(allocator);
        self.click_outside_listeners.deinit(allocator);
    }

    /// Reset listeners for reuse (keeps capacity)
    pub fn resetListeners(self: *Self) void {
        self.click_listeners.clearRetainingCapacity();
        self.click_listeners_ctx.clearRetainingCapacity();
        self.click_listeners_data.clearRetainingCapacity();
        self.mouse_down_listeners.clearRetainingCapacity();
        self.key_down_listeners.clearRetainingCapacity();
        self.simple_key_listeners.clearRetainingCapacity();
        self.action_listeners.clearRetainingCapacity();
        // New handler-based listeners
        self.click_listeners_handler.clearRetainingCapacity();
        self.action_listeners_handler.clearRetainingCapacity();
        self.click_outside_listeners.clearRetainingCapacity();
        // Drag & Drop
        self.drag_source = null;
        self.drop_target = null;
        self.pointer_events_none = false;
    }
};

// =============================================================================
// Event Listeners
// =============================================================================

const event_mod = @import("../core/event.zig");
const input_mod = @import("../input/events.zig");

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

/// Click handler with u32 data (for column/row indices in tables)
pub const ClickListenerWithData = struct {
    callback: *const fn (data: u32) void,
    data: u32,
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

const action_mod = @import("../input/actions.zig");
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

/// Click-outside listener - fires when a click occurs outside this node's bounds
/// Used for closing dropdowns, modals, popups, etc.
pub const ClickOutsideListener = struct {
    /// Simple callback (no context)
    callback: ?*const fn () void = null,
    /// Handler-based callback (with context)
    handler: ?HandlerRef = null,
};

/// Drag source configuration on a dispatch node
pub const DragSource = struct {
    value_ptr: *anyopaque,
    type_id: DragTypeId,
};

/// Drop target configuration on a dispatch node
pub const DropTargetListener = struct {
    type_id: DragTypeId,
    handler: ?HandlerRef,
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

    /// Nodes with click-outside listeners (for fast iteration instead of scanning all nodes)
    click_outside_nodes: std.ArrayListUnmanaged(DispatchNodeId) = .{},

    /// Root node ID
    root: DispatchNodeId = .invalid,

    /// High water mark: max number of nodes ever initialized (for safe reuse)
    /// Only reuse nodes up to this index to avoid using uninitialized memory
    high_water_mark: usize = 0,

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
        // Clean up listeners in all nodes that have been initialized
        // This includes both nodes from previous frames (high_water_mark) and current frame (items.len)
        const backing = self.nodes.allocatedSlice();
        const max_initialized = @max(self.high_water_mark, self.nodes.items.len);
        for (backing[0..max_initialized]) |*node| {
            node.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.node_stack.deinit(self.allocator);
        self.layout_to_node.deinit(self.allocator);
        self.focus_to_node.deinit(self.allocator);
        self.click_outside_nodes.deinit(self.allocator);
    }

    /// Reset tree for a new frame. Clears all nodes but retains capacity.
    pub fn reset(self: *Self) void {
        // Update high water mark before clearing
        if (self.nodes.items.len > self.high_water_mark) {
            self.high_water_mark = self.nodes.items.len;
        }

        // Clear listeners from all nodes up to high water mark (but keep node capacity)
        const backing = self.nodes.allocatedSlice();
        for (backing[0..self.high_water_mark]) |*node| {
            node.resetListeners();
        }

        self.nodes.clearRetainingCapacity();
        self.node_stack.clearRetainingCapacity();
        self.layout_to_node.clearRetainingCapacity();
        self.focus_to_node.clearRetainingCapacity();
        self.click_outside_nodes.clearRetainingCapacity();
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

        // Reuse existing node if within high water mark (nodes that were properly initialized)
        if (self.nodes.items.len < self.high_water_mark) {
            // Access the backing buffer directly to reuse existing node
            self.nodes.items.len += 1;
            const node = &self.nodes.items[node_index];
            // Reset node fields but keep listener array capacities
            node.parent = parent_id;
            node.first_child = .invalid;
            node.next_sibling = .invalid;
            node.bounds = null;
            node.z_index = 0;
            node.has_floating_descendant = false;
            node.layout_id = null;
            node.focus_id = null;
            node.key_context = null;
            node.child_count = 0;
            node.drag_source = null;
            node.drop_target = null;
            node.pointer_events_none = false;
            // Listeners already cleared by resetListeners() in reset()
        } else {
            // Beyond high water mark - append new node (either growing or first use of this slot)
            self.nodes.append(self.allocator, .{
                .parent = parent_id,
            }) catch return .invalid;
        }

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

    /// Set z-index directly for a specific node
    pub fn setZIndex(self: *Self, node_id: DispatchNodeId, z_index: i16) void {
        if (self.getNode(node_id)) |node| {
            node.z_index = z_index;
        }
    }

    /// Mark current node as floating and propagate has_floating_descendant up ancestors.
    /// This enables the hit testing optimization to skip subtrees without floating elements.
    pub fn markFloating(self: *Self) void {
        const node_id = self.currentNode();
        if (!node_id.isValid()) return;

        // Walk up the ancestor chain and mark has_floating_descendant
        var current = node_id;
        while (current.isValid()) {
            const node = self.getNode(current) orelse break;
            // If already marked, ancestors are already marked too
            if (node.has_floating_descendant) break;
            node.has_floating_descendant = true;
            current = node.parent;
        }
    }

    // =========================================================================
    // Hit Testing
    // =========================================================================

    /// Find the deepest node containing the given point.
    /// Z-index aware: prefers higher z-index nodes over lower ones.
    /// Returns null if no node contains the point.
    pub fn hitTest(self: *const Self, x: f32, y: f32) ?DispatchNodeId {
        if (!self.root.isValid()) return null;

        var result: ?DispatchNodeId = null;
        var best_z: i16 = std.math.minInt(i16);
        self.hitTestRecursive(self.root, x, y, &result, &best_z);
        return result;
    }

    fn hitTestRecursive(
        self: *const Self,
        node_id: DispatchNodeId,
        x: f32,
        y: f32,
        result: *?DispatchNodeId,
        best_z: *i16,
    ) void {
        const node = self.getNodeConst(node_id) orelse return;

        // Check if this node contains the point
        const contains_point = if (node.bounds) |bounds|
            x >= bounds.x and x < bounds.x + bounds.width and
                y >= bounds.y and y < bounds.y + bounds.height
        else
            true; // No bounds = assume contains (for structural nodes)

        if (contains_point) {
            // Only accept this node if:
            // - z_index >= best so far (equal z_index: later in tree order wins)
            // - pointer_events_none is false (otherwise transparent to hit testing)
            if (node.z_index >= best_z.* and !node.pointer_events_none) {
                result.* = node_id;
                best_z.* = node.z_index;
            }
        }

        // Optimization: skip children if point is outside AND no floating descendants
        // Floating elements can be positioned outside parent bounds, so we must check them
        if (!contains_point and !node.has_floating_descendant) {
            return;
        }

        // Check children
        var child = node.first_child;
        while (child.isValid()) {
            self.hitTestRecursive(child, x, y, result, best_z);
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

    /// Register a click handler with u32 data on the current node (for table columns/rows)
    pub fn onClickWithData(self: *Self, callback: *const fn (data: u32) void, data: u32) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.click_listeners_data.append(self.allocator, .{
                .callback = callback,
                .data = data,
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

    /// Register a click-outside listener on the current node.
    /// The callback fires when a mouse click occurs outside this node's bounds.
    /// Useful for closing dropdowns, modals, popups, etc.
    pub fn onClickOutside(self: *Self, callback: *const fn () void) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            // Track this node for fast iteration (only if first listener)
            if (node.click_outside_listeners.items.len == 0) {
                self.click_outside_nodes.append(self.allocator, node_id) catch {};
            }
            node.click_outside_listeners.append(self.allocator, .{
                .callback = callback,
            }) catch {};
        }
    }

    /// Register a click-outside listener using HandlerRef (new pattern with context)
    pub fn onClickOutsideHandler(self: *Self, ref: HandlerRef) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            // Track this node for fast iteration (only if first listener)
            if (node.click_outside_listeners.items.len == 0) {
                self.click_outside_nodes.append(self.allocator, node_id) catch {};
            }
            node.click_outside_listeners.append(self.allocator, .{
                .handler = ref,
            }) catch {};
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

            // Call simple click listeners
            for (node.click_listeners.items) |listener| {
                listener.callback();
                return true;
            }

            // Call context click listeners
            for (node.click_listeners_ctx.items) |listener| {
                listener.callback(listener.context);
                return true;
            }

            // Call data click listeners (for table columns/rows)
            for (node.click_listeners_data.items) |listener| {
                listener.callback(listener.data);
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

    /// Check nodes with click-outside listeners and fire them if the click
    /// was outside their bounds AND not on a descendant. Called before normal click handling.
    /// Returns true if any handler was invoked.
    ///
    /// Performance: O(k) where k = nodes with click-outside listeners (typically 0-2)
    /// Note: This computes hitTest internally. If you already have the hit target,
    /// use dispatchClickOutsideWithTarget to avoid redundant hit testing.
    pub fn dispatchClickOutside(self: *Self, x: f32, y: f32, gooey: *Gooey) bool {
        return self.dispatchClickOutsideWithTarget(x, y, self.hitTest(x, y), gooey);
    }

    /// Check nodes with click-outside listeners and fire them if the click
    /// was outside their bounds AND not on a descendant.
    /// Takes a pre-computed hit_target to avoid redundant hit testing.
    /// Returns true if any handler was invoked.
    ///
    /// Performance: O(k) where k = nodes with click-outside listeners (typically 0-2)
    pub fn dispatchClickOutsideWithTarget(self: *Self, x: f32, y: f32, hit_target: ?DispatchNodeId, gooey: *Gooey) bool {
        // Fast path: no click-outside listeners registered
        if (self.click_outside_nodes.items.len == 0) return false;

        var any_fired = false;

        // Only iterate nodes with listeners (typically 0-2 items)
        for (self.click_outside_nodes.items) |node_id| {
            const node = self.getNode(node_id) orelse continue;

            // Check if click is outside this node's bounds
            const is_outside_bounds = if (node.bounds) |bounds|
                x < bounds.x or x >= bounds.x + bounds.width or
                    y < bounds.y or y >= bounds.y + bounds.height
            else
                false; // No bounds = can't determine outside, skip

            // Also check if the hit target is a descendant of this node
            // If so, the click is "inside" even if technically outside bounds
            const is_on_descendant = if (hit_target) |target|
                self.isDescendant(target, node_id)
            else
                false;

            // Only fire if click is outside bounds AND not on a descendant
            if (is_outside_bounds and !is_on_descendant) {
                // Fire all click-outside listeners for this node
                for (node.click_outside_listeners.items) |listener| {
                    if (listener.callback) |cb| {
                        cb();
                        any_fired = true;
                    }
                    if (listener.handler) |handler| {
                        handler.invoke(gooey);
                        any_fired = true;
                    }
                }
            }
        }

        return any_fired;
    }

    /// Check if `potential_descendant` is a descendant of `ancestor`
    fn isDescendant(self: *const Self, potential_descendant: DispatchNodeId, ancestor: DispatchNodeId) bool {
        if (!potential_descendant.isValid() or !ancestor.isValid()) return false;
        if (potential_descendant == ancestor) return true; // Same node counts as "inside"

        // Walk up from potential_descendant to see if we hit ancestor
        var current = potential_descendant;
        while (current.isValid()) {
            const node = self.getNodeConst(current) orelse return false;
            if (node.parent.isValid() and node.parent == ancestor) {
                return true;
            }
            current = node.parent;
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

    // =========================================================================
    // Drag & Drop
    // =========================================================================

    /// Register a drag source on the current node
    pub fn setDragSource(self: *Self, comptime T: type, value: *T) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.drag_source = .{
                .value_ptr = value,
                .type_id = dragTypeId(T),
            };
        }
    }

    /// Register a drop target on the current node
    pub fn setDropTarget(self: *Self, comptime T: type, handler: ?HandlerRef) void {
        const node_id = self.currentNode();
        if (self.getNode(node_id)) |node| {
            node.drop_target = .{
                .type_id = dragTypeId(T),
                .handler = handler,
            };
        }
    }

    /// Find drop target in dispatch path (walks from hit node to root)
    pub fn findDropTarget(self: *Self, path: []const DispatchNodeId, type_id: DragTypeId) ?struct { node_id: DispatchNodeId, handler: ?HandlerRef } {
        for (path) |node_id| {
            if (self.getNodeConst(node_id)) |node| {
                if (node.drop_target) |target| {
                    if (target.type_id == type_id) {
                        return .{ .node_id = node_id, .handler = target.handler };
                    }
                }
            }
        }
        return null;
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

            // Check action listeners
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

test "DispatchTree z-index aware hit testing" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Build tree: root with two overlapping children
    // child1 is earlier in DOM order but has lower z_index
    // child2 (floating dropdown) is later and has higher z_index
    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 200, .height = 200 });

    const child1 = tree.pushNode();
    tree.setBounds(child1, .{ .x = 10, .y = 10, .width = 100, .height = 100 });
    tree.setZIndex(child1, 0);
    tree.popNode();

    // Floating element that overlaps with child1
    const floating = tree.pushNode();
    tree.setBounds(floating, .{ .x = 50, .y = 50, .width = 80, .height = 80 });
    tree.setZIndex(floating, 100); // Higher z-index (like a dropdown)
    tree.popNode();

    tree.popNode();

    // Hit test in overlap area - should return floating (higher z_index)
    const hit1 = tree.hitTest(60, 60);
    try std.testing.expectEqual(floating, hit1.?);

    // Hit test in child1 only area (not overlapping with floating)
    const hit2 = tree.hitTest(15, 15);
    try std.testing.expectEqual(child1, hit2.?);

    // Hit test in floating only area
    const hit3 = tree.hitTest(120, 120);
    try std.testing.expectEqual(floating, hit3.?);

    // Hit test outside both children but inside root
    const hit4 = tree.hitTest(180, 180);
    try std.testing.expectEqual(root, hit4.?);
}

test "DispatchTree z-index equal prefers DOM order" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Two overlapping children with same z-index
    // Later in DOM order should win (like CSS stacking)
    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 200, .height = 200 });

    const child1 = tree.pushNode();
    tree.setBounds(child1, .{ .x = 10, .y = 10, .width = 100, .height = 100 });
    tree.setZIndex(child1, 0);
    tree.popNode();

    const child2 = tree.pushNode();
    tree.setBounds(child2, .{ .x = 50, .y = 50, .width = 100, .height = 100 });
    tree.setZIndex(child2, 0); // Same z-index
    tree.popNode();

    tree.popNode();

    // In overlap area, child2 wins (later in DOM)
    const hit = tree.hitTest(60, 60);
    try std.testing.expectEqual(child2, hit.?);
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

test "DispatchTree click-outside listener fires when click is outside bounds" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Track if callback was fired
    const State = struct {
        var fired: bool = false;
        fn callback() void {
            fired = true;
        }
    };
    State.fired = false;

    // Create a dropdown-like element with click-outside listener
    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 400, .height = 400 });

    const dropdown = tree.pushNode();
    tree.setBounds(dropdown, .{ .x = 100, .y = 100, .width = 100, .height = 50 });
    tree.onClickOutside(State.callback);
    tree.popNode();

    tree.popNode();

    // Click inside dropdown - should NOT fire
    _ = tree.dispatchClickOutside(150, 125, undefined);
    try std.testing.expect(!State.fired);

    // Click outside dropdown - should fire
    _ = tree.dispatchClickOutside(50, 50, undefined);
    try std.testing.expect(State.fired);
}

test "DispatchTree click-outside does not fire when click is inside bounds" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const State = struct {
        var fired: bool = false;
        fn callback() void {
            fired = true;
        }
    };
    State.fired = false;

    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 200, .height = 200 });
    tree.onClickOutside(State.callback);
    tree.popNode();

    // Click inside - should NOT fire
    _ = tree.dispatchClickOutside(100, 100, undefined);
    try std.testing.expect(!State.fired);

    // Click at edge (still inside) - should NOT fire
    _ = tree.dispatchClickOutside(0, 0, undefined);
    try std.testing.expect(!State.fired);

    // Click just outside right edge - should fire
    _ = tree.dispatchClickOutside(200, 100, undefined);
    try std.testing.expect(State.fired);
}

test "DispatchTree multiple click-outside listeners" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const State = struct {
        var dropdown1_closed: bool = false;
        var dropdown2_closed: bool = false;

        fn closeDropdown1() void {
            dropdown1_closed = true;
        }
        fn closeDropdown2() void {
            dropdown2_closed = true;
        }
    };
    State.dropdown1_closed = false;
    State.dropdown2_closed = false;

    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 400, .height = 400 });

    // Dropdown 1 at left
    const dropdown1 = tree.pushNode();
    tree.setBounds(dropdown1, .{ .x = 10, .y = 10, .width = 80, .height = 50 });
    tree.onClickOutside(State.closeDropdown1);
    tree.popNode();

    // Dropdown 2 at right
    const dropdown2 = tree.pushNode();
    tree.setBounds(dropdown2, .{ .x = 200, .y = 10, .width = 80, .height = 50 });
    tree.onClickOutside(State.closeDropdown2);
    tree.popNode();

    tree.popNode();

    // Click inside dropdown1 but outside dropdown2
    _ = tree.dispatchClickOutside(50, 30, undefined);
    try std.testing.expect(!State.dropdown1_closed); // Inside dropdown1
    try std.testing.expect(State.dropdown2_closed); // Outside dropdown2

    // Reset
    State.dropdown1_closed = false;
    State.dropdown2_closed = false;

    // Click outside both
    _ = tree.dispatchClickOutside(150, 200, undefined);
    try std.testing.expect(State.dropdown1_closed);
    try std.testing.expect(State.dropdown2_closed);
}

test "DispatchTree hit testing skips subtrees without floating descendants" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Build tree:
    //   root
    //   ├── container (no floating) - should early-exit when point outside
    //   │   └── nested_child
    //   └── floating_container (has floating descendant)
    //       └── floating_child (positioned outside parent bounds)

    const root = tree.pushNode();
    tree.setBounds(root, .{ .x = 0, .y = 0, .width = 500, .height = 500 });

    // Container without floating - hit test should skip its children when outside
    const container = tree.pushNode();
    tree.setBounds(container, .{ .x = 10, .y = 10, .width = 100, .height = 100 });
    // Note: has_floating_descendant defaults to false

    const nested_child = tree.pushNode();
    tree.setBounds(nested_child, .{ .x = 20, .y = 20, .width = 50, .height = 50 });
    tree.popNode();

    tree.popNode();

    // Container with floating descendant
    const floating_container = tree.pushNode();
    tree.setBounds(floating_container, .{ .x = 200, .y = 10, .width = 100, .height = 100 });

    // Floating child positioned OUTSIDE its parent's bounds
    const floating_child = tree.pushNode();
    tree.setBounds(floating_child, .{ .x = 200, .y = 200, .width = 80, .height = 80 }); // Way below parent
    tree.setZIndex(floating_child, 100);
    tree.markFloating(); // This marks ancestors as has_floating_descendant
    tree.popNode();

    tree.popNode();

    tree.popNode();

    // Verify has_floating_descendant was propagated
    const floating_container_node = tree.getNodeConst(floating_container).?;
    try std.testing.expect(floating_container_node.has_floating_descendant);

    const container_node = tree.getNodeConst(container).?;
    try std.testing.expect(!container_node.has_floating_descendant);

    // Hit test inside nested_child - should find it
    const hit1 = tree.hitTest(30, 30);
    try std.testing.expectEqual(nested_child, hit1.?);

    // Hit test outside container but where nested_child would be if it floated
    // Should NOT find nested_child because container has no floating descendants
    const hit2 = tree.hitTest(150, 50);
    try std.testing.expectEqual(root, hit2.?);

    // Hit test in floating_child (which is outside its parent's bounds)
    // Should find it because floating_container has has_floating_descendant=true
    const hit3 = tree.hitTest(220, 220);
    try std.testing.expectEqual(floating_child, hit3.?);
}

test "DispatchTree markFloating propagates up ancestor chain" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    // Build deep tree: root -> a -> b -> c -> floating
    const root = tree.pushNode();
    const a = tree.pushNode();
    const b = tree.pushNode();
    const c = tree.pushNode();
    const floating = tree.pushNode();
    tree.markFloating();
    tree.popNode();
    tree.popNode();
    tree.popNode();
    tree.popNode();
    tree.popNode();

    // All ancestors should have has_floating_descendant=true
    try std.testing.expect(tree.getNodeConst(root).?.has_floating_descendant);
    try std.testing.expect(tree.getNodeConst(a).?.has_floating_descendant);
    try std.testing.expect(tree.getNodeConst(b).?.has_floating_descendant);
    try std.testing.expect(tree.getNodeConst(c).?.has_floating_descendant);
    try std.testing.expect(tree.getNodeConst(floating).?.has_floating_descendant);
}

test "DispatchTree click_outside_nodes tracks only nodes with listeners" {
    const allocator = std.testing.allocator;
    var tree = DispatchTree.init(allocator);
    defer tree.deinit();

    const noop = struct {
        fn callback() void {}
    }.callback;

    const root = tree.pushNode();
    // No listener on root

    const child1 = tree.pushNode();
    tree.onClickOutside(noop); // First listener
    tree.popNode();

    const child2 = tree.pushNode();
    // No listener on child2
    tree.popNode();

    const child3 = tree.pushNode();
    tree.onClickOutside(noop); // Second listener
    tree.popNode();

    tree.popNode();

    // Should only have 2 nodes tracked (child1 and child3)
    try std.testing.expectEqual(@as(usize, 2), tree.click_outside_nodes.items.len);
    try std.testing.expectEqual(child1, tree.click_outside_nodes.items[0]);
    try std.testing.expectEqual(child3, tree.click_outside_nodes.items[1]);

    _ = root;
    _ = child2;
}
