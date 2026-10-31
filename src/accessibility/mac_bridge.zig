//! macOS Accessibility Bridge using NSAccessibility
//!
//! Provides VoiceOver support by translating Gooey's accessibility tree
//! to native NSAccessibilityElement objects. Uses a pooled wrapper approach
//! for zero-allocation after init.
//!
//! Strategy:
//! - Pre-allocated pool of NSAccessibilityElement wrappers
//! - Fingerprint-based identity mapping for stable object references
//! - Value and caret change notifications for elements whose content changed
//! - Periodic VoiceOver detection (not every frame)

const std = @import("std");
const objc = @import("objc");
const bridge_mod = @import("bridge.zig");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const constants = @import("constants.zig");
const layout = @import("../layout/layout.zig");
const appkit = @import("../platform/macos/appkit.zig");
const TextSelection = @import("element.zig").TextSelection;

/// The `GooeyMetalView` ivar holding the focused element, which the view
/// returns from `accessibilityFocusedUIElement` so VoiceOver follows Gooey's
/// focus into its elements (AppKit asks the first responder).
pub const focus_ivar = "_gooeyAccessibilityFocus";

// ============================================================================
// External Declarations
// ============================================================================

/// NSAccessibilityFocusedUIElementChangedNotification
extern "c" var NSAccessibilityFocusedUIElementChangedNotification: objc.c.id;

/// NSAccessibilityValueChangedNotification
extern "c" var NSAccessibilityValueChangedNotification: objc.c.id;

/// NSAccessibilitySelectedTextChangedNotification
extern "c" var NSAccessibilitySelectedTextChangedNotification: objc.c.id;

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
        @as([constants.MAX_ELEMENTS]fingerprint_mod.Fingerprint, @splat(fingerprint_mod.Fingerprint.INVALID)),

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

        /// `valueHash` at the last sync; null before the first.
        value_hash: ?u64 = null,

        /// Selection at the last sync; null when not the focused field.
        selection: ?TextSelection = null,

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

            // Set value. A toggle without a text value reports its checked
            // state as VoiceOver expects (0 or 1); otherwise a value that
            // went away is cleared, so a reused wrapper never reports stale
            // text.
            if (elem.value) |value| {
                setAccessibilityValue(ns, value);
            } else if (isToggle(elem.role)) {
                setAccessibilityChecked(ns, elem.state.checked);
            } else {
                clearAccessibilityValue(ns);
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

            self.notifyChanges(ns, elem);

            // Update tracking
            self.fingerprint = elem.fingerprint;
            self.active = true;
        }

        /// Tell VoiceOver what changed since this element's last sync, as
        /// NSTextView and NSButton do: the value (text or checked state) and
        /// the focused field's selection. A wrapper's first sync posts
        /// nothing, because the element is new to VoiceOver. At most two
        /// notifications per dirty element, and a frame has one selection.
        fn notifyChanges(self: *Wrapper, ns: objc.Object, elem: *const tree_mod.Element) void {
            std.debug.assert(ns.value != null);
            std.debug.assert(elem.fingerprint.isValid());
            const value_hash = valueHash(elem);
            const value_changed = if (self.value_hash) |previous| previous != value_hash else false;
            var moved_from: ?TextSelection = null;
            if (self.selection) |previous| {
                if (elem.selection) |current| {
                    if (!std.meta.eql(previous, current)) moved_from = previous;
                }
            }
            self.value_hash = value_hash;
            self.selection = elem.selection;
            if (isText(elem.role)) {
                setAccessibilitySelectedTextRange(ns, selectedRange(elem));
            }
            if (value_changed) postNotification(ns, NSAccessibilityValueChangedNotification);
            const previous = moved_from orelse return;
            if (value_changed) {
                // An edit moved the caret; VoiceOver echoes it from the value.
                postNotification(ns, NSAccessibilitySelectedTextChangedNotification);
            } else {
                const text = elem.value orelse "";
                postSelectionMove(ns, selectionMove(previous, elem.selection.?, text));
            }
        }

        /// Mark wrapper as inactive (available for reuse)
        pub fn invalidate(self: *Wrapper) void {
            // Assertion: wrapper was active
            std.debug.assert(self.active or self.fingerprint.eql(fingerprint_mod.Fingerprint.INVALID));

            self.active = false;
            self.fingerprint = fingerprint_mod.Fingerprint.INVALID;
            self.value_hash = null;
            self.selection = null;
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
        registerElementClass();

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

        // Elements hang under the content view, not the window: replacing the
        // window's children would hide its titlebar buttons from VoiceOver.
        const root = self.content_view orelse self.root_element orelse return;

        // Sync each dirty element
        for (dirty) |idx| {
            self.syncElement(tree, idx, root);
        }

        // Update children arrays for VoiceOver discovery
        self.updateAccessibilityChildren(tree, root);
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
        const root_children = objc.Object.fromId(root_children_id);

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
        const children = objc.Object.fromId(children_id);

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

        // Resolve parent's NS element. A top-level element's parent is the
        // window, as in 0.3.1, even though it hangs in the content view's
        // children: AppKit ignores the content view, so an AXParent naming it
        // points outside the chain VoiceOver walks (#121 regression).
        const parent_ns = self.resolveParentNS(tree, elem, self.root_element orelse root);

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
        std.debug.assert(@backingInt(live) <= @backingInt(types.Live.assertive));

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

        const ns = self.focusedElement(tree, idx);
        self.publishFocus(ns);
        if (ns) |element| postFocusChangedNotification(element);
    }

    fn focusedElement(self: *Self, tree: *const tree_mod.Tree, idx: ?u16) ?objc.Object {
        std.debug.assert(tree.count() <= constants.MAX_ELEMENTS);
        const focus_idx = idx orelse return null;
        const elem = tree.getElement(focus_idx) orelse return null;
        const slot = self.findSlotByFingerprint(elem.fingerprint) orelse return null;
        return self.wrappers[slot].ns_element;
    }

    /// Hand the focused element, or nil, to the view (`focus_ivar`). The
    /// view does not retain it; the wrapper pool keeps it alive until
    /// `deinit_` clears the ivar first.
    fn publishFocus(self: *Self, ns: ?objc.Object) void {
        const view = self.content_view orelse return;
        std.debug.assert(view.value != null);
        view.setInstanceVariable(focus_ivar, ns orelse .{ .value = null });
    }

    fn isActive(ptr: *anyopaque) bool {
        const self = castSelf(ptr);

        // Update cached state
        self.voiceover_active = checkVoiceOverRunning();
        return self.voiceover_active;
    }

    fn deinit_(ptr: *anyopaque) void {
        const self = castSelf(ptr);

        // The view must not hand VoiceOver an element released below.
        self.publishFocus(null);

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
    const cls = element_class.?;
    // Standard Objective-C pattern: [[GooeyAccessibilityElement alloc] init]
    const alloc_id: objc.c.id = cls.msgSend(objc.c.id, "alloc", .{});
    if (alloc_id == null) return null;
    const alloc_obj = objc.Object.fromId(alloc_id);
    const elem_id: objc.c.id = alloc_obj.msgSend(objc.c.id, "init", .{});
    if (elem_id == null) return null;
    return objc.Object.fromId(elem_id);
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

fn clearAccessibilityValue(elem: objc.Object) void {
    std.debug.assert(elem.value != null);
    elem.msgSend(void, "setAccessibilityValue:", .{@as(objc.c.id, null)});
}

fn isToggle(role: types.Role) bool {
    return role == .checkbox or role == .radio or role == .switch_;
}

fn setAccessibilityChecked(elem: objc.Object, checked: bool) void {
    std.debug.assert(elem.value != null);
    const NSNumber = objc.getClass("NSNumber") orelse return;
    const number: objc.c.id = NSNumber.msgSend(objc.c.id, "numberWithBool:", .{checked});
    std.debug.assert(number != null);
    elem.msgSend(void, "setAccessibilityValue:", .{number});
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
    // Zig 0.16: ?[*c]T is not allowed in C calling convention; [*c] is already nullable.
    const window_rect: NSRect = view.msgSend(NSRect, "convertRect:toView:", .{ view_rect, @as(objc.c.id, @ptrFromInt(0)) });

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

fn postFocusChangedNotification(elem: objc.Object) void {
    std.debug.assert(elem.value != null);
    postNotification(elem, NSAccessibilityFocusedUIElementChangedNotification);
}

fn postNotification(elem: objc.Object, notification: objc.c.id) void {
    std.debug.assert(elem.value != null);
    std.debug.assert(notification != null);
    const post = @extern(*const fn (objc.c.id, objc.c.id) callconv(.c) void, .{
        .name = "NSAccessibilityPostNotification",
    });
    post(elem.value, notification);
}

/// The value VoiceOver reads: the text, or a toggle's checked state.
fn valueHash(elem: *const tree_mod.Element) u64 {
    var hasher = std.hash.Wyhash.init(0);
    if (elem.value) |value| {
        hasher.update("text:");
        hasher.update(value);
    } else if (isToggle(elem.role)) {
        hasher.update(if (elem.state.checked) "checked" else "unchecked");
    }
    return hasher.final();
}

fn isText(role: types.Role) bool {
    return role == .textbox or role == .textarea or role == .searchbox;
}

/// The focused field's selection in UTF-16 units, as AppKit counts; an
/// unfocused field reports an empty range at the start.
fn selectedRange(elem: *const tree_mod.Element) appkit.NSRange {
    const selection = elem.selection orelse return .{ .location = 0, .length = 0 };
    const text = elem.value orelse "";
    std.debug.assert(selection.start <= selection.end);
    std.debug.assert(selection.end <= text.len);
    return .{
        .location = utf16Length(text[0..selection.start]),
        .length = utf16Length(text[selection.start..selection.end]),
    };
}

fn setAccessibilitySelectedTextRange(elem: objc.Object, range: appkit.NSRange) void {
    std.debug.assert(elem.value != null);
    elem.msgSend(void, "setAccessibilitySelectedTextRange:", .{range});
}

/// UTF-16 code units in UTF-8 `text`: one per scalar, two above U+FFFF.
/// Counts lead bytes, so it is bounded by `text.len` and needs no decode.
fn utf16Length(text: []const u8) u32 {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var count: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
        if (byte >= 0xF0) count += 1;
    }
    std.debug.assert(count <= text.len);
    return count;
}

test "utf16Length counts surrogate pairs" {
    try std.testing.expectEqual(@as(u32, 0), utf16Length(""));
    try std.testing.expectEqual(@as(u32, 3), utf16Length("abc"));
    // é is 2 bytes and 1 unit, 日 is 3 bytes and 1 unit, 😀 is 4 bytes and 2 units.
    try std.testing.expectEqual(@as(u32, 5), utf16Length("é日😀a"));
}

// ============================================================================
// GooeyAccessibilityElement: NSAccessibilityElement with text queries
// ============================================================================

/// Registered once, at the first bridge's initialization.
var element_class: ?objc.Class = null;

/// VoiceOver reads and echoes a text field through the NSAccessibility text
/// methods, which NSAccessibilityElement leaves unimplemented: without them
/// it reports zero characters, refuses `AXStringForRange`, and keeps reading
/// a cached value. Each answer derives from the element's value and selected
/// range, which `Wrapper.update` sets, so there is no second copy to go
/// stale. The field is one line, so line queries answer line 0.
fn registerElementClass() void {
    if (element_class != null) return;
    const NSAccessibilityElement = objc.getClass("NSAccessibilityElement") orelse
        @panic("NSAccessibilityElement class not found");
    const cls = objc.allocateClassPair(NSAccessibilityElement, "GooeyAccessibilityElement") orelse
        @panic("GooeyAccessibilityElement class allocation failed");
    const methods = .{
        .{ "accessibilityNumberOfCharacters", textNumberOfCharacters },
        .{ "accessibilitySelectedText", textSelected },
        .{ "accessibilityVisibleCharacterRange", textVisibleRange },
        .{ "accessibilityInsertionPointLineNumber", textInsertionLine },
        .{ "accessibilityStringForRange:", textStringForRange },
        .{ "accessibilityAttributedStringForRange:", textAttributedStringForRange },
        .{ "accessibilityFrameForRange:", textFrameForRange },
        .{ "accessibilityLineForIndex:", textLineForIndex },
        .{ "accessibilityRangeForLine:", textRangeForLine },
        .{ "accessibilityRangeForIndex:", textRangeForIndex },
    };
    inline for (methods) |method| {
        if (!cls.addMethod(method[0], method[1])) {
            std.debug.panic("GooeyAccessibilityElement: adding {s} failed", .{method[0]});
        }
    }
    objc.registerClassPair(cls);
    element_class = cls;
}

/// The element's value when it is text (a toggle's is an NSNumber).
fn textValue(self: objc.c.id) ?objc.Object {
    std.debug.assert(self != null);
    const element = objc.Object.fromId(self);
    const value: objc.c.id = element.msgSend(objc.c.id, "accessibilityValue", .{});
    if (value == null) return null;
    const NSString = objc.getClass("NSString").?;
    const string = objc.Object.fromId(value);
    if (!string.msgSend(bool, "isKindOfClass:", .{NSString.value})) return null;
    return string;
}

fn textLength(self: objc.c.id) c_ulong {
    const text = textValue(self) orelse return 0;
    return text.msgSend(c_ulong, "length", .{});
}

/// `range` clamped to the text, so a stale query never raises.
fn textClamp(range: appkit.NSRange, length: c_ulong) appkit.NSRange {
    const location = @min(range.location, length);
    const clamped: appkit.NSRange = .{
        .location = location,
        .length = @min(range.length, length - location),
    };
    std.debug.assert(clamped.location + clamped.length <= length);
    return clamped;
}

fn textNumberOfCharacters(self: objc.c.id, _: objc.c.SEL) callconv(.c) c_long {
    return @intCast(textLength(self));
}

fn textSelected(self: objc.c.id, _: objc.c.SEL) callconv(.c) objc.c.id {
    const element = objc.Object.fromId(self);
    const range = element.msgSend(appkit.NSRange, "accessibilitySelectedTextRange", .{});
    return textStringForRange(self, undefined, range);
}

fn textVisibleRange(self: objc.c.id, _: objc.c.SEL) callconv(.c) appkit.NSRange {
    return .{ .location = 0, .length = textLength(self) };
}

fn textInsertionLine(self: objc.c.id, _: objc.c.SEL) callconv(.c) c_long {
    std.debug.assert(self != null);
    return 0;
}

fn textStringForRange(
    self: objc.c.id,
    _: objc.c.SEL,
    range: appkit.NSRange,
) callconv(.c) objc.c.id {
    const text = textValue(self) orelse return null;
    const clamped = textClamp(range, text.msgSend(c_ulong, "length", .{}));
    return text.msgSend(objc.c.id, "substringWithRange:", .{clamped});
}

fn textAttributedStringForRange(
    self: objc.c.id,
    _: objc.c.SEL,
    range: appkit.NSRange,
) callconv(.c) objc.c.id {
    const string = textStringForRange(self, undefined, range);
    if (string == null) return null;
    const NSAttributedString = objc.getClass("NSAttributedString").?;
    const allocated = NSAttributedString.msgSend(objc.Object, "alloc", .{});
    const attributed = allocated.msgSend(objc.Object, "initWithString:", .{string});
    return attributed.msgSend(objc.c.id, "autorelease", .{});
}

/// The whole field for any range: Gooey does not expose glyph positions to
/// the bridge. VoiceOver's arguments are external input, so the text queries
/// clamp them rather than assert.
fn textFrameForRange(self: objc.c.id, _: objc.c.SEL, _: appkit.NSRange) callconv(.c) appkit.NSRect {
    std.debug.assert(self != null);
    const element = objc.Object.fromId(self);
    return element.msgSend(appkit.NSRect, "accessibilityFrame", .{});
}

fn textLineForIndex(self: objc.c.id, _: objc.c.SEL, _: c_long) callconv(.c) c_long {
    std.debug.assert(self != null);
    return 0;
}

fn textRangeForLine(self: objc.c.id, _: objc.c.SEL, line: c_long) callconv(.c) appkit.NSRange {
    if (line != 0) return .{ .location = 0, .length = 0 };
    return .{ .location = 0, .length = textLength(self) };
}

/// One UTF-16 unit at `index`; VoiceOver widens to a composed character.
fn textRangeForIndex(self: objc.c.id, _: objc.c.SEL, index: c_long) callconv(.c) appkit.NSRange {
    const location: c_ulong = @intCast(@max(index, 0));
    return textClamp(.{ .location = location, .length = 1 }, textLength(self));
}

/// How a selection change reads to VoiceOver, in the `AXTextStateChangeType`,
/// `AXTextSelectionDirection`, and `AXTextSelectionGranularity` values WebKit
/// and Chromium post. Without them VoiceOver stays silent on caret moves in an
/// element that is not an NSTextView.
const SelectionMove = struct {
    kind: Kind,
    direction: Direction,
    granularity: Granularity,

    const Kind = enum(u8) { move = 2, extend = 3 };
    const Direction = enum(u8) {
        unknown = 0,
        beginning = 1,
        end = 2,
        previous = 3,
        next = 4,
        discontiguous = 5,
    };
    const Granularity = enum(u8) { unknown = 0, character = 1, word = 2, line = 3 };
};

/// Infer the move from the selections before and after, since the bridge
/// sees frames, not keys. One scalar is a character move; a longer move to
/// either end of the one-line field is a line move (Home, End, Cmd+arrow);
/// any other is a word move (Option+arrow). Collapsing a selection, or
/// moving both ends, is discontiguous (a click).
fn selectionMove(previous: TextSelection, current: TextSelection, text: []const u8) SelectionMove {
    std.debug.assert(previous.start <= previous.end);
    std.debug.assert(current.end <= text.len);
    const kind: SelectionMove.Kind = if (current.start == current.end) .move else .extend;
    const discontiguous: SelectionMove = .{
        .kind = kind,
        .direction = .discontiguous,
        .granularity = .unknown,
    };
    var from: u32 = undefined;
    var to: u32 = undefined;
    if (previous.start == previous.end) {
        if (current.start == previous.start) {
            from = previous.end;
            to = current.end;
        } else {
            from = previous.start;
            to = current.start;
        }
    } else {
        if (kind == .move) return discontiguous;
        if (current.start == previous.start) {
            from = previous.end;
            to = current.end;
        } else if (current.end == previous.end) {
            from = previous.start;
            to = current.start;
        } else {
            return discontiguous;
        }
    }
    return spanMove(kind, from, to, text);
}

/// Classify a move of one selection end from `from` to `to`.
fn spanMove(kind: SelectionMove.Kind, from: u32, to: u32, text: []const u8) SelectionMove {
    std.debug.assert(from != to);
    std.debug.assert(@max(from, to) <= text.len);
    const forward = to > from;
    const span = text[@min(from, to)..@max(from, to)];
    const direction: SelectionMove.Direction = if (forward) .next else .previous;
    if (scalarCount(span) == 1) {
        return .{ .kind = kind, .direction = direction, .granularity = .character };
    }
    if (to == 0) return .{ .kind = kind, .direction = .beginning, .granularity = .line };
    if (to == text.len) return .{ .kind = kind, .direction = .end, .granularity = .line };
    return .{ .kind = kind, .direction = direction, .granularity = .word };
}

/// Unicode scalars in UTF-8 `text`: its lead bytes.
fn scalarCount(text: []const u8) u32 {
    std.debug.assert(text.len <= std.math.maxInt(u32));
    var count: u32 = 0;
    for (text) |byte| {
        if (byte & 0xC0 != 0x80) count += 1;
    }
    return count;
}

/// `AXSelectedTextChanged` with the move's userInfo, as WebKit posts it.
fn postSelectionMove(elem: objc.Object, move: SelectionMove) void {
    std.debug.assert(elem.value != null);
    const NSNumber = objc.getClass("NSNumber").?;
    const NSDictionary = objc.getClass("NSDictionary").?;
    const keys = [_]objc.c.id{
        (createNSString("AXTextStateChangeType") orelse return).value,
        (createNSString("AXTextSelectionDirection") orelse return).value,
        (createNSString("AXTextSelectionGranularity") orelse return).value,
        (createNSString("AXTextChangeElement") orelse return).value,
    };
    const values = [_]objc.c.id{
        NSNumber.msgSend(objc.c.id, "numberWithInt:", .{@as(c_int, @backingInt(move.kind))}),
        NSNumber.msgSend(objc.c.id, "numberWithInt:", .{@as(c_int, @backingInt(move.direction))}),
        NSNumber.msgSend(objc.c.id, "numberWithInt:", .{
            @as(c_int, @backingInt(move.granularity)),
        }),
        elem.value,
    };
    const info: objc.c.id = NSDictionary.msgSend(
        objc.c.id,
        "dictionaryWithObjects:forKeys:count:",
        .{ &values, &keys, @as(c_ulong, keys.len) },
    );
    std.debug.assert(info != null);
    const post = @extern(*const fn (objc.c.id, objc.c.id, objc.c.id) callconv(.c) void, .{
        .name = "NSAccessibilityPostNotificationWithUserInfo",
    });
    post(elem.value, NSAccessibilitySelectedTextChangedNotification, info);
}

test "selectionMove infers how the caret moved" {
    // Goal: VoiceOver reads a character, word, or line for the matching key.
    // Methodology: the selections each TextInput key produces in "ab cé"
    // ("é" is two bytes, one scalar), against the move a reader expects.
    const text = "ab c\u{e9}";
    const Case = struct { from: TextSelection, to: TextSelection, expected: SelectionMove };
    const cases = [_]Case{
        // Left over "é" is one character back, though two bytes.
        .{ .from = .{ .start = 6, .end = 6 }, .to = .{ .start = 4, .end = 4 }, .expected = .{
            .kind = .move,
            .direction = .previous,
            .granularity = .character,
        } },
        .{ .from = .{ .start = 0, .end = 0 }, .to = .{ .start = 1, .end = 1 }, .expected = .{
            .kind = .move,
            .direction = .next,
            .granularity = .character,
        } },
        // Option+Left from the end stops at the word start.
        .{ .from = .{ .start = 6, .end = 6 }, .to = .{ .start = 3, .end = 3 }, .expected = .{
            .kind = .move,
            .direction = .previous,
            .granularity = .word,
        } },
        .{ .from = .{ .start = 4, .end = 4 }, .to = .{ .start = 0, .end = 0 }, .expected = .{
            .kind = .move,
            .direction = .beginning,
            .granularity = .line,
        } },
        .{ .from = .{ .start = 0, .end = 0 }, .to = .{ .start = 6, .end = 6 }, .expected = .{
            .kind = .move,
            .direction = .end,
            .granularity = .line,
        } },
        // Shift+Left extends from the caret; a second keeps the anchor.
        .{ .from = .{ .start = 6, .end = 6 }, .to = .{ .start = 4, .end = 6 }, .expected = .{
            .kind = .extend,
            .direction = .previous,
            .granularity = .character,
        } },
        .{ .from = .{ .start = 4, .end = 6 }, .to = .{ .start = 3, .end = 6 }, .expected = .{
            .kind = .extend,
            .direction = .previous,
            .granularity = .character,
        } },
        // Collapsing a selection, or selecting elsewhere, has no direction.
        .{ .from = .{ .start = 3, .end = 6 }, .to = .{ .start = 3, .end = 3 }, .expected = .{
            .kind = .move,
            .direction = .discontiguous,
            .granularity = .unknown,
        } },
        .{ .from = .{ .start = 0, .end = 1 }, .to = .{ .start = 3, .end = 6 }, .expected = .{
            .kind = .extend,
            .direction = .discontiguous,
            .granularity = .unknown,
        } },
    };
    for (cases) |case| {
        const actual = selectionMove(case.from, case.to, text);
        try std.testing.expectEqual(case.expected.kind, actual.kind);
        try std.testing.expectEqual(case.expected.direction, actual.direction);
        try std.testing.expectEqual(case.expected.granularity, actual.granularity);
    }
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
    return objc.Object.fromId(ns_id);
}

fn createNSStringFromSlice(str: []const u8) ?objc.Object {
    std.debug.assert(str.len <= 65535);

    const NSString = objc.getClass("NSString") orelse return null;
    const alloc_id: objc.c.id = NSString.msgSend(objc.c.id, "alloc", .{});
    if (alloc_id == null) return null;

    const ns = objc.Object.fromId(alloc_id);
    const init_id: objc.c.id = ns.msgSend(
        objc.c.id,
        "initWithBytes:length:encoding:",
        .{ str.ptr, @as(c_ulong, str.len), NSUTF8StringEncoding },
    );
    if (init_id == null) return null;

    return objc.Object.fromId(init_id);
}

fn releaseNSObject(obj: objc.Object) void {
    if (obj.value != null) {
        obj.release();
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
