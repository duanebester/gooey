//! macOS Accessibility Bridge using NSAccessibility
//!
//! Provides VoiceOver support by translating Gooey's accessibility tree
//! to native NSAccessibilityElement objects. Uses a pooled wrapper approach
//! for zero-allocation after init.
//!
//! Strategy:
//! - Pre-allocated pool of NSAccessibilityElement wrappers
//! - Fingerprint-based identity mapping for stable object references
//! - Batched property updates with single layout notification
//! - Periodic VoiceOver detection (not every frame)

const std = @import("std");
const objc = @import("objc");
const bridge_mod = @import("bridge.zig");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const constants = @import("constants.zig");
const layout = @import("../layout/layout.zig");

// ============================================================================
// External Declarations
// ============================================================================

/// NSAccessibilityFocusedUIElementChangedNotification
extern "c" var NSAccessibilityFocusedUIElementChangedNotification: objc.c.id;

/// NSAccessibilityLayoutChangedNotification
extern "c" var NSAccessibilityLayoutChangedNotification: objc.c.id;

/// NSAccessibilityAnnouncementRequestedNotification
extern "c" var NSAccessibilityAnnouncementRequestedNotification: objc.c.id;

/// NSAccessibilityAnnouncementKey
extern "c" var NSAccessibilityAnnouncementKey: objc.c.id;

/// NSAccessibilityPriorityKey
extern "c" var NSAccessibilityPriorityKey: objc.c.id;

// ============================================================================
// Constants
// ============================================================================

/// NSAccessibilityPriorityHigh - for assertive announcements
const NSAccessibilityPriorityHigh: c_long = 90;

/// NSAccessibilityPriorityMedium - for polite announcements
const NSAccessibilityPriorityMedium: c_long = 50;

/// NSUTF8StringEncoding
const NSUTF8StringEncoding: c_ulong = 4;

// ============================================================================
// MacBridge
// ============================================================================

pub const MacBridge = struct {
    /// Pool of native accessibility element wrappers (static allocation)
    wrappers: [constants.MAX_ELEMENTS]Wrapper = undefined,
    wrapper_count: u16 = 0,

    /// Map fingerprint -> wrapper slot for stable identity
    /// Linear search is fine for typical element counts (<500)
    fingerprint_to_slot: [constants.MAX_ELEMENTS]fingerprint_mod.Fingerprint =
        [_]fingerprint_mod.Fingerprint{fingerprint_mod.Fingerprint.INVALID} ** constants.MAX_ELEMENTS,

    /// Root accessibility element (the window)
    root_element: ?objc.Object = null,

    /// Content view for coordinate conversion (view coords -> screen coords)
    content_view: ?objc.Object = null,

    /// Cached VoiceOver state (checked periodically, not every frame)
    voiceover_active: bool = false,

    /// Frame counter for periodic checks
    check_counter: u32 = 0,

    const Self = @This();

    // =========================================================================
    // Wrapper - Native Element Container
    // =========================================================================

    const Wrapper = struct {
        /// The native NSAccessibilityElement
        ns_element: ?objc.Object = null,

        /// Last synced fingerprint (for identity tracking)
        fingerprint: fingerprint_mod.Fingerprint = fingerprint_mod.Fingerprint.INVALID,

        /// Is this slot currently in use?
        active: bool = false,

        /// Update wrapper from accessibility element
        pub fn update(
            self: *Wrapper,
            elem: *const tree_mod.Element,
            parent_ns: objc.Object,
            ns_window: ?objc.Object,
            content_view: ?objc.Object,
        ) void {
            // Assertion: element must have valid fingerprint
            std.debug.assert(elem.fingerprint.isValid());
            // Assertion: parent must be valid
            std.debug.assert(parent_ns.value != null);

            // Lazily create NS element if needed
            if (self.ns_element == null) {
                self.ns_element = createNSAccessibilityElement();
                if (self.ns_element == null) return;
            }

            const ns = self.ns_element.?;

            // Set role
            setAccessibilityRole(ns, elem.role);

            // Set label (name)
            if (elem.name) |name| {
                setAccessibilityLabel(ns, name);
            } else {
                clearAccessibilityLabel(ns);
            }

            // Set value
            if (elem.value) |value| {
                setAccessibilityValue(ns, value);
            }

            // Set parent relationship
            setAccessibilityParent(ns, parent_ns);

            // Set state properties
            setAccessibilityEnabled(ns, !elem.state.disabled);
            setAccessibilityFocused(ns, elem.state.focused);

            // Set bounds if available (non-zero size indicates valid bounds)
            // Convert from view coordinates to screen coordinates for accessibility
            if (elem.bounds.width > 0 and elem.bounds.height > 0) {
                const screen_bounds = convertToScreenRect(elem.bounds, ns_window, content_view);
                setAccessibilityFrame(ns, screen_bounds);
            }

            // Update tracking
            self.fingerprint = elem.fingerprint;
            self.active = true;
        }

        /// Mark wrapper as inactive (available for reuse)
        pub fn invalidate(self: *Wrapper) void {
            // Assertion: wrapper was active
            std.debug.assert(self.active or self.fingerprint.eql(fingerprint_mod.Fingerprint.INVALID));

            self.active = false;
            self.fingerprint = fingerprint_mod.Fingerprint.INVALID;
            // NOTE: Don't release ns_element - we reuse it from the pool
        }
    };

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize the macOS accessibility bridge
    /// Call after window creation with the main window and view objects
    ///
    /// Parameters:
    ///   window: NSWindow object (for screen coordinate conversion)
    ///   view: NSView object (the content view where layout coordinates are relative to)
    pub fn init(window: ?objc.Object, view: ?objc.Object) Self {
        var self = Self{};

        // Pre-initialize wrapper pool
        for (&self.wrappers) |*w| {
            w.* = Wrapper{};
        }

        self.root_element = window;
        // Store view directly - layout bounds are in view coordinates
        self.content_view = view;

        self.voiceover_active = checkVoiceOverRunning();

        return self;
    }

    /// Get the Bridge interface (vtable pattern)
    pub fn bridge(self: *Self) bridge_mod.Bridge {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    const vtable = bridge_mod.Bridge.VTable{
        .syncDirty = syncDirty,
        .removeElements = removeElements,
        .announce = announce_,
        .focusChanged = focusChanged,
        .isActive = isActive,
        .deinit = deinit_,
    };

    // =========================================================================
    // Bridge Implementation
    // =========================================================================

    fn syncDirty(
        ptr: *anyopaque,
        tree: *const tree_mod.Tree,
        dirty: []const u16,
    ) void {
        const self = castSelf(ptr);

        // Assertion: dirty list is bounded
        std.debug.assert(dirty.len <= constants.MAX_ELEMENTS);
        // Assertion: self is valid
        std.debug.assert(self.root_element != null or !self.voiceover_active);

        if (!self.voiceover_active) return;
        if (dirty.len == 0) return;

        const root = self.root_element orelse return;

        // Sync each dirty element
        for (dirty) |idx| {
            self.syncElement(tree, idx, root);
        }

        // Update children arrays for VoiceOver discovery
        self.updateAccessibilityChildren(tree, root);

        // Post layout changed notification (batched)
        postLayoutChangedNotification(root);
    }

    /// Update accessibilityChildren on root and parent elements
    /// VoiceOver requires children to be set on parents for element discovery
    fn updateAccessibilityChildren(self: *Self, tree: *const tree_mod.Tree, root: objc.Object) void {
        // Assertion: root is valid
        std.debug.assert(root.value != null);
        // Assertion: tree element count is bounded
        std.debug.assert(tree.count() <= constants.MAX_ELEMENTS);

        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;

        // Collect all top-level elements (parent == null in tree)
        const root_children_id: objc.c.id = NSMutableArray.msgSend(objc.c.id, "array", .{});
        if (root_children_id == null) return;
        const root_children = objc.Object{ .value = root_children_id };

        // Iterate through all elements and add top-level ones to root's children
        var i: u16 = 0;
        while (i < tree.count()) : (i += 1) {
            const elem = tree.getElement(i) orelse continue;

            // Find the wrapper for this element
            const slot = self.findSlotByFingerprint(elem.fingerprint) orelse continue;
            const ns = self.wrappers[slot].ns_element orelse continue;

            // If element has no parent in tree, it's a child of root
            if (elem.parent == null) {
                root_children.msgSend(void, "addObject:", .{ns.value});
            }

            // Update children for elements that have children in the tree
            if (elem.child_count > 0) {
                self.updateElementChildren(tree, elem, ns);
            }
        }

        // Set children on root element
        setAccessibilityChildren(root, root_children);
    }

    /// Update accessibilityChildren for a single element
    fn updateElementChildren(
        self: *Self,
        tree: *const tree_mod.Tree,
        elem: *const tree_mod.Element,
        ns: objc.Object,
    ) void {
        // Assertion: element has children
        std.debug.assert(elem.child_count > 0);
        // Assertion: ns element is valid
        std.debug.assert(ns.value != null);

        const NSMutableArray = objc.getClass("NSMutableArray") orelse return;

        const children_id: objc.c.id = NSMutableArray.msgSend(objc.c.id, "array", .{});
        if (children_id == null) return;
        const children = objc.Object{ .value = children_id };

        // Walk through children via linked list
        var child_idx = elem.first_child;
        while (child_idx) |idx| {
            const child_elem = tree.getElement(idx) orelse break;
            const child_slot = self.findSlotByFingerprint(child_elem.fingerprint) orelse {
                child_idx = child_elem.next_sibling;
                continue;
            };
            const child_ns = self.wrappers[child_slot].ns_element orelse {
                child_idx = child_elem.next_sibling;
                continue;
            };

            children.msgSend(void, "addObject:", .{child_ns.value});
            child_idx = child_elem.next_sibling;
        }

        setAccessibilityChildren(ns, children);
    }

    fn syncElement(
        self: *Self,
        tree: *const tree_mod.Tree,
        idx: u16,
        root: objc.Object,
    ) void {
        // Assertion: index in bounds
        std.debug.assert(idx < constants.MAX_ELEMENTS);

        const elem = tree.getElement(idx) orelse return;

        // Find or allocate wrapper slot
        const slot = self.findOrAllocSlot(elem.fingerprint) orelse return;

        // Resolve parent's NS element
        const parent_ns = self.resolveParentNS(tree, elem, root);

        // Update the wrapper with coordinate conversion context
        self.wrappers[slot].update(elem, parent_ns, self.root_element, self.content_view);
    }

    fn resolveParentNS(
        self: *Self,
        tree: *const tree_mod.Tree,
        elem: *const tree_mod.Element,
        root: objc.Object,
    ) objc.Object {
        // Assertion: inputs are valid
        std.debug.assert(root.value != null);

        const parent_idx = elem.parent orelse return root;
        const parent_elem = tree.getElement(parent_idx) orelse return root;
        const parent_slot = self.findSlotByFingerprint(parent_elem.fingerprint) orelse return root;
        return self.wrappers[parent_slot].ns_element orelse root;
    }

    fn removeElements(ptr: *anyopaque, fingerprints: []const fingerprint_mod.Fingerprint) void {
        const self = castSelf(ptr);

        // Assertion: removal list bounded
        std.debug.assert(fingerprints.len <= constants.MAX_ELEMENTS);

        for (fingerprints) |fp| {
            if (self.findSlotByFingerprint(fp)) |slot| {
                self.wrappers[slot].invalidate();
                self.fingerprint_to_slot[slot] = fingerprint_mod.Fingerprint.INVALID;
            }
        }
    }

    fn announce_(ptr: *anyopaque, message: []const u8, live: types.Live) void {
        const self = castSelf(ptr);

        // Assertion: message is bounded
        std.debug.assert(message.len <= 65535);
        // Assertion: live level is valid
        std.debug.assert(@intFromEnum(live) <= @intFromEnum(types.Live.assertive));

        if (!self.voiceover_active) return;
        if (live == .off) return;

        const root = self.root_element orelse return;
        postAnnouncement(root, message, live);
    }

    fn focusChanged(ptr: *anyopaque, tree: *const tree_mod.Tree, idx: ?u16) void {
        const self = castSelf(ptr);

        // Assertion: tree is valid
        std.debug.assert(tree.count() <= constants.MAX_ELEMENTS);

        if (!self.voiceover_active) return;

        const focus_idx = idx orelse return;
        const elem = tree.getElement(focus_idx) orelse return;
        const slot = self.findSlotByFingerprint(elem.fingerprint) orelse return;
        const ns = self.wrappers[slot].ns_element orelse return;

        postFocusChangedNotification(ns);
    }

    fn isActive(ptr: *anyopaque) bool {
        const self = castSelf(ptr);

        // Update cached state
        self.voiceover_active = checkVoiceOverRunning();
        return self.voiceover_active;
    }

    fn deinit_(ptr: *anyopaque) void {
        const self = castSelf(ptr);

        // Release all NS objects
        for (&self.wrappers) |*w| {
            if (w.ns_element) |ns| {
                releaseNSObject(ns);
                w.ns_element = null;
            }
            w.active = false;
            w.fingerprint = fingerprint_mod.Fingerprint.INVALID;
        }

        self.root_element = null;
        self.content_view = null;
        self.voiceover_active = false;
    }

    // =========================================================================
    // Slot Management
    // =========================================================================

    fn findSlotByFingerprint(self: *Self, fp: fingerprint_mod.Fingerprint) ?u16 {
        // Assertion: fingerprint is valid
        std.debug.assert(fp.isValid());

        for (self.fingerprint_to_slot, 0..) |slot_fp, i| {
            if (slot_fp.eql(fp)) return @intCast(i);
        }
        return null;
    }

    pub fn findOrAllocSlot(self: *Self, fp: fingerprint_mod.Fingerprint) ?u16 {
        // Assertion: fingerprint is valid
        std.debug.assert(fp.isValid());
        // Assertion: wrapper_count is bounded
        std.debug.assert(self.wrapper_count <= constants.MAX_ELEMENTS);

        // Try existing slot
        if (self.findSlotByFingerprint(fp)) |slot| return slot;

        // Find free slot
        for (&self.wrappers, 0..) |*w, i| {
            if (!w.active) {
                self.fingerprint_to_slot[i] = fp;
                w.active = true; // Mark as allocated
                w.fingerprint = fp;
                if (i >= self.wrapper_count) {
                    self.wrapper_count = @intCast(i + 1);
                }
                return @intCast(i);
            }
        }

        // Pool exhausted - fail gracefully
        return null;
    }

    fn castSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }
};

// ============================================================================
// Objective-C Helpers
// ============================================================================

fn createNSAccessibilityElement() ?objc.Object {
    const cls = objc.getClass("NSAccessibilityElement") orelse return null;
    // Standard Objective-C pattern: [[NSAccessibilityElement alloc] init]
    const alloc_id: objc.c.id = cls.msgSend(objc.c.id, "alloc", .{});
    if (alloc_id == null) return null;
    const alloc_obj = objc.Object{ .value = alloc_id };
    const elem_id: objc.c.id = alloc_obj.msgSend(objc.c.id, "init", .{});
    if (elem_id == null) return null;
    return objc.Object{ .value = elem_id };
}

fn setAccessibilityRole(elem: objc.Object, role: types.Role) void {
    // Assertion: element is valid
    std.debug.assert(elem.value != null);

    const role_str = role.toNSRole();
    const ns_role = createNSString(role_str) orelse return;
    defer releaseNSObject(ns_role);

    elem.msgSend(void, "setAccessibilityRole:", .{ns_role.value});
}

fn setAccessibilityLabel(elem: objc.Object, label: []const u8) void {
    // Assertion: element is valid
    std.debug.assert(elem.value != null);
    // Assertion: label is bounded
    std.debug.assert(label.len <= 65535);

    const ns_label = createNSStringFromSlice(label) orelse return;
    defer releaseNSObject(ns_label);

    elem.msgSend(void, "setAccessibilityLabel:", .{ns_label.value});
}

fn clearAccessibilityLabel(elem: objc.Object) void {
    std.debug.assert(elem.value != null);
    elem.msgSend(void, "setAccessibilityLabel:", .{@as(objc.c.id, null)});
}

fn setAccessibilityValue(elem: objc.Object, value: []const u8) void {
    std.debug.assert(elem.value != null);
    std.debug.assert(value.len <= 65535);

    const ns_value = createNSStringFromSlice(value) orelse return;
    defer releaseNSObject(ns_value);

    elem.msgSend(void, "setAccessibilityValue:", .{ns_value.value});
}

fn setAccessibilityParent(elem: objc.Object, parent: objc.Object) void {
    std.debug.assert(elem.value != null);
    std.debug.assert(parent.value != null);

    elem.msgSend(void, "setAccessibilityParent:", .{parent.value});
}

fn setAccessibilityChildren(elem: objc.Object, children: objc.Object) void {
    std.debug.assert(elem.value != null);
    std.debug.assert(children.value != null);

    elem.msgSend(void, "setAccessibilityChildren:", .{children.value});
}

fn setAccessibilityEnabled(elem: objc.Object, enabled: bool) void {
    std.debug.assert(elem.value != null);
    elem.msgSend(void, "setAccessibilityEnabled:", .{enabled});
}

fn setAccessibilityFocused(elem: objc.Object, focused: bool) void {
    std.debug.assert(elem.value != null);
    elem.msgSend(void, "setAccessibilityFocused:", .{focused});
}

/// NSRect type for Cocoa coordinate conversion
const NSRect = extern struct {
    origin: extern struct { x: f64, y: f64 },
    size: extern struct { width: f64, height: f64 },
};

/// Convert view-local bounds to screen coordinates for accessibility.
/// macOS accessibility requires screen coordinates (origin at bottom-left of screen).
/// Layout bounds are in view coordinates (origin at top-left of view, flipped).
fn convertToScreenRect(
    bounds: layout.BoundingBox,
    ns_window: ?objc.Object,
    content_view: ?objc.Object,
) layout.BoundingBox {
    // Assertion: bounds are valid
    std.debug.assert(!std.math.isNan(bounds.x) and !std.math.isNan(bounds.y));

    const window = ns_window orelse return bounds;
    const view = content_view orelse return bounds;

    // Create NSRect in view coordinates
    const view_rect = NSRect{
        .origin = .{ .x = @floatCast(bounds.x), .y = @floatCast(bounds.y) },
        .size = .{ .width = @floatCast(bounds.width), .height = @floatCast(bounds.height) },
    };

    // Convert view coords -> window coords (handles flipped coordinate system)
    const window_rect: NSRect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(?objc.c.id, null) });

    // Convert window coords -> screen coords (handles multiple monitors)
    const screen_rect: NSRect = window.msgSend(NSRect, "convertRectToScreen:", .{window_rect});

    return layout.BoundingBox{
        .x = @floatCast(screen_rect.origin.x),
        .y = @floatCast(screen_rect.origin.y),
        .width = @floatCast(screen_rect.size.width),
        .height = @floatCast(screen_rect.size.height),
    };
}

fn setAccessibilityFrame(elem: objc.Object, bounds: layout.BoundingBox) void {
    std.debug.assert(elem.value != null);
    // Assertion: bounds are valid (default bounds have x=0, y=0 which is valid)
    std.debug.assert(!std.math.isNan(bounds.x) and !std.math.isNan(bounds.y));

    // NSRect for setAccessibilityFrame (requires f64 for Cocoa)
    // Bounds should already be in screen coordinates from convertToScreenRect
    const frame = NSRect{
        .origin = .{ .x = @floatCast(bounds.x), .y = @floatCast(bounds.y) },
        .size = .{ .width = @floatCast(bounds.width), .height = @floatCast(bounds.height) },
    };

    elem.msgSend(void, "setAccessibilityFrame:", .{frame});
}

fn postLayoutChangedNotification(root: objc.Object) void {
    std.debug.assert(root.value != null);

    const NSAccessibilityCenter = objc.getClass("NSAccessibility") orelse return;
    _ = NSAccessibilityCenter;

    // NSAccessibilityPostNotification(root, NSAccessibilityLayoutChangedNotification)
    const postNotification = @extern(*const fn (objc.c.id, objc.c.id) callconv(std.builtin.CallingConvention.c) void, .{
        .name = "NSAccessibilityPostNotification",
    });
    postNotification(root.value, NSAccessibilityLayoutChangedNotification);
}

fn postFocusChangedNotification(elem: objc.Object) void {
    std.debug.assert(elem.value != null);

    const postNotification = @extern(*const fn (objc.c.id, objc.c.id) callconv(std.builtin.CallingConvention.c) void, .{
        .name = "NSAccessibilityPostNotification",
    });
    postNotification(elem.value, NSAccessibilityFocusedUIElementChangedNotification);
}

fn postAnnouncement(root: objc.Object, message: []const u8, live: types.Live) void {
    std.debug.assert(root.value != null);
    std.debug.assert(message.len <= 65535);

    const ns_message = createNSStringFromSlice(message) orelse return;
    defer releaseNSObject(ns_message);

    // Create userInfo dictionary
    const NSDictionary = objc.getClass("NSDictionary") orelse return;
    const NSNumber = objc.getClass("NSNumber") orelse return;

    // Priority based on live level
    const priority: c_long = switch (live) {
        .assertive => NSAccessibilityPriorityHigh,
        .polite => NSAccessibilityPriorityMedium,
        .off => return,
    };

    const ns_priority = NSNumber.msgSend(objc.Object, "numberWithLong:", .{priority});

    // Build dictionary: @{ NSAccessibilityAnnouncementKey: message, NSAccessibilityPriorityKey: priority }
    const keys = [_]objc.c.id{ NSAccessibilityAnnouncementKey, NSAccessibilityPriorityKey };
    const values = [_]objc.c.id{ ns_message.value, ns_priority.value };

    const dict_id: objc.c.id = NSDictionary.msgSend(
        objc.c.id,
        "dictionaryWithObjects:forKeys:count:",
        .{ &values, &keys, @as(c_ulong, 2) },
    );
    if (dict_id == null) return;

    // Post notification with userInfo
    const postNotificationWithUserInfo = @extern(*const fn (objc.c.id, objc.c.id, objc.c.id) callconv(std.builtin.CallingConvention.c) void, .{
        .name = "NSAccessibilityPostNotificationWithUserInfo",
    });
    postNotificationWithUserInfo(root.value, NSAccessibilityAnnouncementRequestedNotification, dict_id);
}

fn checkVoiceOverRunning() bool {
    // Query NSWorkspace.sharedWorkspace.isVoiceOverEnabled
    // Available in macOS 10.13+
    const NSWorkspace = objc.getClass("NSWorkspace") orelse return false;
    const workspace = NSWorkspace.msgSend(objc.Object, "sharedWorkspace", .{});
    return workspace.msgSend(bool, "isVoiceOverEnabled", .{});
}

// ============================================================================
// NSString Helpers
// ============================================================================

fn createNSString(str: []const u8) ?objc.Object {
    std.debug.assert(str.len <= 65535);

    const NSString = objc.getClass("NSString") orelse return null;
    const ns_id: objc.c.id = NSString.msgSend(
        objc.c.id,
        "stringWithUTF8String:",
        .{str.ptr},
    );
    if (ns_id == null) return null;
    return objc.Object{ .value = ns_id };
}

fn createNSStringFromSlice(str: []const u8) ?objc.Object {
    std.debug.assert(str.len <= 65535);

    const NSString = objc.getClass("NSString") orelse return null;
    const alloc_id: objc.c.id = NSString.msgSend(objc.c.id, "alloc", .{});
    if (alloc_id == null) return null;

    const ns = objc.Object{ .value = alloc_id };
    const init_id: objc.c.id = ns.msgSend(
        objc.c.id,
        "initWithBytes:length:encoding:",
        .{ str.ptr, @as(c_ulong, str.len), NSUTF8StringEncoding },
    );
    if (init_id == null) return null;

    return objc.Object{ .value = init_id };
}

fn releaseNSObject(obj: objc.Object) void {
    if (obj.value != null) {
        obj.msgSend(void, "release", .{});
    }
}

// ============================================================================
// Compile-Time Assertions (per CLAUDE.md)
// ============================================================================

comptime {
    // MacBridge should fit in reasonable stack space
    std.debug.assert(@sizeOf(MacBridge) <= 1024 * 1024); // 1MB max

    // Wrapper should be cache-friendly
    std.debug.assert(@sizeOf(MacBridge.Wrapper) <= 64); // Fit in cache line
}

// ============================================================================
// Tests
// ============================================================================

test "mac bridge initialization" {
    var bridge_impl = MacBridge.init(null, null);
    const b = bridge_impl.bridge();

    // Should work with null window (VoiceOver disabled)
    try std.testing.expect(!b.isActive());
}

test "mac bridge wrapper lifecycle" {
    var wrapper = MacBridge.Wrapper{};

    // Initial state
    try std.testing.expect(!wrapper.active);
    try std.testing.expect(!wrapper.fingerprint.isValid());

    // Invalidate is safe on inactive wrapper
    wrapper.active = true;
    wrapper.fingerprint = fingerprint_mod.compute(.button, "Test", null, 0);
    wrapper.invalidate();

    try std.testing.expect(!wrapper.active);
    try std.testing.expect(!wrapper.fingerprint.isValid());
}

test "mac bridge slot management" {
    var bridge_impl = MacBridge.init(null, null);

    const fp1 = fingerprint_mod.compute(.button, "Button1", null, 0);
    const fp2 = fingerprint_mod.compute(.button, "Button2", null, 1);

    // Allocate slots
    const slot1 = bridge_impl.findOrAllocSlot(fp1);
    const slot2 = bridge_impl.findOrAllocSlot(fp2);

    try std.testing.expect(slot1 != null);
    try std.testing.expect(slot2 != null);
    try std.testing.expect(slot1.? != slot2.?);

    // Find existing slot
    const found = bridge_impl.findSlotByFingerprint(fp1);
    try std.testing.expectEqual(slot1, found);

    // Same fingerprint returns same slot
    const slot1_again = bridge_impl.findOrAllocSlot(fp1);
    try std.testing.expectEqual(slot1, slot1_again);
}

test "role to ns role mapping" {
    // Verify key mappings exist and are reasonable
    try std.testing.expectEqualStrings("AXButton", types.Role.button.toNSRole());
    try std.testing.expectEqualStrings("AXCheckBox", types.Role.checkbox.toNSRole());
    try std.testing.expectEqualStrings("AXTextField", types.Role.textbox.toNSRole());
    try std.testing.expectEqualStrings("AXSlider", types.Role.slider.toNSRole());
    try std.testing.expectEqualStrings("AXDialog", types.Role.dialog.toNSRole());
}
