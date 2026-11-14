//! macOS Accessibility Bridge using NSAccessibility
//!
//! Provides VoiceOver support by translating Gooey's accessibility tree
//! to native NSAccessibilityElement objects. Uses a pooled wrapper approach
//! for zero-allocation after init.
//!
//! Strategy:
//! - Pool of NSAccessibilityElement wrappers, one per `a11y.element_count_max`,
//!   reserved at init from fresh pages
//! - Fingerprint-based identity mapping for stable object references
//! - Value and caret change notifications for elements whose content changed
//! - Periodic VoiceOver detection (not every frame)

const std = @import("std");
const objc = @import("objc");
const bridge_mod = @import("bridge.zig");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const Fingerprint = fingerprint_mod.Fingerprint;
const reservation = @import("../core/reservation.zig");
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
    /// Pool of native accessibility element wrappers, `a11y.element_count_max`
    /// of them, reserved at init; empty when the reservation failed.
    wrappers: []Wrapper = &.{},
    /// Slots below this were initialized; the rest are untouched pages.
    wrapper_count: u16 = 0,

    /// Map fingerprint -> wrapper slot for stable identity
    /// Linear search is fine for typical element counts (<500)
    fingerprint_to_slot: []fingerprint_mod.Fingerprint = &.{},

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

    /// No screen frame has width -1, so a wrapper's first frame always sets.
    const frame_unset = layout.BoundingBox{ .x = 0, .y = 0, .width = -1, .height = -1 };

    const Wrapper = struct {
        /// The native NSAccessibilityElement
        ns_element: ?objc.Object = null,

        /// Last synced fingerprint (for identity tracking)
        fingerprint: fingerprint_mod.Fingerprint = fingerprint_mod.Fingerprint.INVALID,

        /// Is this slot currently in use?
        active: bool = false,

        /// `valueHash` at the last sync; meaningful once `value_synced`.
        value_hash: u64 = 0,
        /// Whether `value_hash` holds a sync's hash (a flag beside a plain
        /// hash keeps the wrapper in 64 bytes, as `frame_unset` does).
        value_synced: bool = false,

        /// Selection at the last sync; null when not the focused field.
        selection: ?TextSelection = null,

        // What `ns_element` itself holds, so a sync sets only what changed.
        // Both survive `invalidate`: a reused wrapper keeps its native object.
        /// The screen frame last set; `frame_unset` before the first (a
        /// sentinel rather than an optional keeps the wrapper in 64 bytes).
        frame: layout.BoundingBox = frame_unset,
        /// Whether children were last set non-empty.
        has_children: bool = false,
        /// Whether previous and next contents were last set (a splitter).
        has_contents: bool = false,

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
            setAccessibilityRoleDescription(ns, roleDescription(elem.role));

            // Set label (name)
            if (elem.name) |name| {
                setAccessibilityLabel(ns, name);
            } else {
                clearAccessibilityLabel(ns);
            }
            // VoiceOver reads a splitter's title, never its label
            // (AXDescription), so a splitter carries its name as both.
            const title = if (elem.role == .separator) elem.name else null;
            setAccessibilityTitle(ns, title);

            // Set value. A toggle or option without a text value reports
            // whether it is on as VoiceOver expects (0 or 1); otherwise a
            // value that went away is cleared, so a reused wrapper never
            // reports stale text.
            if (elem.value) |value| {
                setAccessibilityValue(ns, value);
            } else if (toggleState(elem)) |on| {
                setAccessibilityChecked(ns, on);
            } else if (elem.value_now) |now| {
                // A splitter or slider without a text value reports its
                // position as a number in its range, as NSSlider does.
                setAccessibilityRange(ns, elem.value_min orelse now, elem.value_max orelse now, now);
            } else {
                clearAccessibilityValue(ns);
            }
            // Unknown when null, which a reused wrapper needs as well.
            setAccessibilityOrientation(ns, elem.orientation);

            // Set parent relationship
            setAccessibilityParent(ns, parent_ns);

            // Set state properties
            setAccessibilityEnabled(ns, !elem.state.disabled);
            setAccessibilityFocused(ns, elem.state.focused);
            if (isSelectable(elem.role)) setAccessibilitySelected(ns, elem.state.selected);

            self.refreshFrame(elem, ns_window, content_view);
            self.notifyChanges(ns, elem);

            // Update tracking
            self.fingerprint = elem.fingerprint;
            self.active = true;
        }

        /// Set the element's screen frame when it moved. Bounds are in view
        /// coordinates, so a scroll, a layout shift, or a window move changes
        /// the frame without changing the element's content; zero-size
        /// bounds carry no frame.
        fn refreshFrame(
            self: *Wrapper,
            elem: *const tree_mod.Element,
            ns_window: ?objc.Object,
            content_view: ?objc.Object,
        ) void {
            const ns = self.ns_element.?;
            std.debug.assert(elem.fingerprint.isValid());
            if (elem.bounds.width <= 0 or elem.bounds.height <= 0) return;
            const screen = convertToScreenRect(elem.bounds, ns_window, content_view);
            std.debug.assert(screen.width >= 0);
            if (std.meta.eql(self.frame, screen)) return;
            setAccessibilityFrame(ns, screen);
            self.frame = screen;
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
            const value_changed = self.value_synced and self.value_hash != value_hash;
            var selection_moved = false;
            if (self.selection) |previous| {
                if (elem.selection) |current| selection_moved = !std.meta.eql(previous, current);
            }
            self.value_hash = value_hash;
            self.value_synced = true;
            self.selection = elem.selection;
            if (isText(elem.role)) {
                setAccessibilitySelectedTextRange(ns, selectedRange(elem));
            }
            if (value_changed) postNotification(ns, NSAccessibilityValueChangedNotification);
            if (selection_moved) {
                postNotification(ns, NSAccessibilitySelectedTextChangedNotification);
            }
        }

        /// Mark wrapper as inactive (available for reuse)
        pub fn invalidate(self: *Wrapper) void {
            // Assertion: wrapper was active
            std.debug.assert(self.active or self.fingerprint.eql(fingerprint_mod.Fingerprint.INVALID));

            self.active = false;
            self.fingerprint = fingerprint_mod.Fingerprint.INVALID;
            self.value_hash = 0;
            self.value_synced = false;
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
    /// `element_count_max` is the tree's (`a11y.element_count_max`): stale
    /// wrappers are reclaimed before a new one is taken, so the frame's
    /// elements always fit. A failed reservation leaves the bridge inert, as
    /// the Windows bridge does: the app runs without VoiceOver support and the
    /// error is logged.
    pub fn init(element_count_max: u16, window: ?objc.Object, view: ?objc.Object) Self {
        std.debug.assert(element_count_max > 0);
        var self = Self{};
        self.reserveSlots(element_count_max) catch {
            std.log.err("accessibility: VoiceOver wrapper reservation failed", .{});
            return self;
        };
        std.debug.assert(self.wrappers.len == element_count_max);

        self.root_element = window;
        // Store view directly - layout bounds are in view coordinates
        self.content_view = view;

        self.voiceover_active = checkVoiceOverRunning();
        registerElementClass();

        return self;
    }

    /// Wrapper slots from fresh pages: a slot is initialized when first
    /// taken, so only the slots VoiceOver ever used become resident.
    fn reserveSlots(self: *Self, element_count_max: u16) error{OutOfMemory}!void {
        const wrappers = try reservation.reserve(Wrapper, element_count_max);
        errdefer reservation.release(Wrapper, wrappers, 0);

        self.fingerprint_to_slot = try reservation.reserve(Fingerprint, element_count_max);
        self.wrappers = wrappers;
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
        std.debug.assert(dirty.len <= tree.count());
        // Assertion: self is valid
        std.debug.assert(self.root_element != null or !self.voiceover_active);

        if (!self.voiceover_active) return;

        // Elements hang under the content view, not the window: replacing the
        // window's children would hide its titlebar buttons from VoiceOver.
        const root = self.content_view orelse self.root_element orelse return;

        // Sync each dirty element
        for (dirty) |idx| {
            self.syncElement(tree, idx, root);
        }

        // Every frame, as `windows_bridge.syncDirty` does: bounds move
        // without a content change, so clean elements' frames are refreshed
        // too, setting only the ones that moved.
        self.refreshFrames(tree);

        // Children change only when an element was added, changed, or
        // removed; removed elements are already gone from `tree`.
        if (dirty.len > 0 or tree.getRemovedFingerprints().len > 0) {
            self.updateAccessibilityChildren(tree, root);
        }
    }

    /// One pass over the allocated wrappers, at most `a11y.element_count_max`, each an
    /// O(1) tree lookup and one view-to-screen conversion; a frame is set
    /// only for an element that moved.
    fn refreshFrames(self: *Self, tree: *const tree_mod.Tree) void {
        std.debug.assert(self.wrapper_count <= self.wrappers.len);
        std.debug.assert(self.voiceover_active);
        for (self.wrappers[0..self.wrapper_count]) |*wrapper| {
            if (!wrapper.active) continue;
            if (wrapper.ns_element == null) continue;
            const index = tree.findElementByFingerprint(wrapper.fingerprint) orelse continue;
            const elem = tree.getElement(index).?;
            wrapper.refreshFrame(elem, self.root_element, self.content_view);
        }
    }

    /// Update accessibilityChildren on root and parent elements
    /// VoiceOver requires children to be set on parents for element discovery
    fn updateAccessibilityChildren(self: *Self, tree: *const tree_mod.Tree, root: objc.Object) void {
        // Assertion: root is valid
        std.debug.assert(root.value != null);
        // Assertion: tree element count is bounded
        std.debug.assert(tree.count() <= tree.elements.len);

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
            if (elem.parent == null) self.addNativeChild(tree, elem, root_children);

            // Update children for elements that have children in the tree.
            // A leaf clears what its native object held: a pooled wrapper
            // reused for a leaf would otherwise keep its old children. A
            // combobox is a leaf to VoiceOver (see `addNativeChild`).
            const wrapper = &self.wrappers[slot];
            if (elem.child_count > 0 and elem.role != .combobox) {
                self.updateElementChildren(tree, elem, ns);
                wrapper.has_children = true;
            } else if (wrapper.has_children) {
                const empty_id: objc.c.id = NSMutableArray.msgSend(objc.c.id, "array", .{});
                if (empty_id == null) continue;
                setAccessibilityChildren(ns, objc.Object.fromId(empty_id));
                wrapper.has_children = false;
            }
        }

        // Set children on root element
        setAccessibilityChildren(root, root_children);
        self.updateSplitterContents(tree);
    }

    /// Give each splitter the elements on either side of it, as NSSplitView
    /// does: VoiceOver calls a splitter with no previous or next contents
    /// "collapsed" toward that side. Its neighbours are its siblings in the
    /// tree, which are in index order (the tree is built depth first). One
    /// scan of at most `a11y.element_count_max` per splitter.
    fn updateSplitterContents(self: *Self, tree: *const tree_mod.Tree) void {
        std.debug.assert(tree.count() <= tree.elements.len);
        std.debug.assert(self.wrapper_count <= self.wrappers.len);
        var index: u16 = 0;
        while (index < tree.count()) : (index += 1) {
            const elem = tree.getElement(index) orelse continue;
            const slot = self.findSlotByFingerprint(elem.fingerprint) orelse continue;
            const wrapper = &self.wrappers[slot];
            const ns = wrapper.ns_element orelse continue;
            if (elem.role == .separator) {
                const previous = self.siblingElement(tree, index, .previous);
                const next = self.siblingElement(tree, index, .next);
                setAccessibilityContents(ns, "setAccessibilityPreviousContents:", previous);
                setAccessibilityContents(ns, "setAccessibilityNextContents:", next);
                wrapper.has_contents = true;
            } else if (wrapper.has_contents) {
                setAccessibilityContents(ns, "setAccessibilityPreviousContents:", null);
                setAccessibilityContents(ns, "setAccessibilityNextContents:", null);
                wrapper.has_contents = false;
            }
        }
    }

    /// The native element of the sibling just before or after `index`.
    fn siblingElement(
        self: *Self,
        tree: *const tree_mod.Tree,
        index: u16,
        side: enum { previous, next },
    ) ?objc.Object {
        std.debug.assert(index < tree.count());
        const parent = tree.getElement(index).?.parent;
        var found: ?u16 = null;
        var other: u16 = 0;
        while (other < tree.count()) : (other += 1) {
            if (other == index) {
                if (side == .previous) break;
                continue;
            }
            const elem = tree.getElement(other) orelse continue;
            if (!std.meta.eql(elem.parent, parent)) continue;
            if (side == .previous) {
                found = other;
            } else {
                if (other > index) {
                    found = other;
                    break;
                }
            }
        }
        const sibling = tree.getElement(found orelse return null).?;
        return self.nativeElement(sibling);
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
            self.addNativeChild(tree, child_elem, children);
            child_idx = child_elem.next_sibling;
        }

        setAccessibilityChildren(ns, children);
    }

    /// Add `elem`'s native element to `children`, followed by a combobox's
    /// own children (its popup listbox): VoiceOver treats an element with
    /// children as a container and, when focus returns to it, puts its
    /// cursor back on the child it last visited, so a combobox holding its
    /// list sent VoiceOver into the closed list instead of onto the box.
    /// The listbox is the box's sibling to VoiceOver, as `resolveParentNS`
    /// says. One level, at most `child_count` children.
    fn addNativeChild(
        self: *Self,
        tree: *const tree_mod.Tree,
        elem: *const tree_mod.Element,
        children: objc.Object,
    ) void {
        std.debug.assert(children.value != null);
        std.debug.assert(elem.fingerprint.isValid());
        if (self.nativeElement(elem)) |ns| children.msgSend(void, "addObject:", .{ns.value});
        if (elem.role != .combobox) return;
        var added: u16 = 0;
        var child_idx = elem.first_child;
        while (child_idx) |idx| : (added += 1) {
            std.debug.assert(added < elem.child_count);
            const child_elem = tree.getElement(idx) orelse break;
            if (self.nativeElement(child_elem)) |ns| {
                children.msgSend(void, "addObject:", .{ns.value});
            }
            child_idx = child_elem.next_sibling;
        }
    }

    fn nativeElement(self: *Self, elem: *const tree_mod.Element) ?objc.Object {
        std.debug.assert(elem.fingerprint.isValid());
        std.debug.assert(self.wrapper_count <= self.wrappers.len);
        const slot = self.findSlotByFingerprint(elem.fingerprint) orelse return null;
        return self.wrappers[slot].ns_element;
    }

    fn syncElement(
        self: *Self,
        tree: *const tree_mod.Tree,
        idx: u16,
        root: objc.Object,
    ) void {
        // Assertion: index in bounds
        std.debug.assert(idx < tree.count());

        const elem = tree.getElement(idx) orelse return;

        // Find or allocate a wrapper slot. When every slot is taken, some hold
        // elements that left the tree in frames the bridge skipped (VoiceOver
        // was off); reclaiming them leaves at most the tree's elements, which
        // the pool always holds.
        const slot = self.findOrAllocSlot(elem.fingerprint) orelse blk: {
            self.reclaimStale(tree);
            break :blk self.findOrAllocSlot(elem.fingerprint) orelse unreachable;
        };

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
        std.debug.assert(elem.fingerprint.isValid());

        var parent_elem = tree.getElement(elem.parent orelse return root) orelse return root;
        // A combobox's children hang beside it (see `addNativeChild`).
        if (parent_elem.role == .combobox) {
            parent_elem = tree.getElement(parent_elem.parent orelse return root) orelse return root;
        }
        const parent_slot = self.findSlotByFingerprint(parent_elem.fingerprint) orelse return root;
        return self.wrappers[parent_slot].ns_element orelse root;
    }

    fn removeElements(ptr: *anyopaque, fingerprints: []const fingerprint_mod.Fingerprint) void {
        const self = castSelf(ptr);

        // Assertion: removal list bounded
        std.debug.assert(fingerprints.len <= self.wrappers.len);

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
        std.debug.assert(tree.count() <= tree.elements.len);

        if (!self.voiceover_active) return;

        const ns = self.focusedElement(tree, idx);
        self.publishFocus(ns);
        if (ns) |element| postFocusChangedNotification(element);
    }

    fn focusedElement(self: *Self, tree: *const tree_mod.Tree, idx: ?u16) ?objc.Object {
        std.debug.assert(tree.count() <= tree.elements.len);
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

        // An inert bridge (its reservation failed) never syncs.
        if (self.wrappers.len == 0) return false;
        // Update cached state
        self.voiceover_active = checkVoiceOverRunning();
        return self.voiceover_active;
    }

    fn deinit_(ptr: *anyopaque) void {
        const self = castSelf(ptr);

        // The view must not hand VoiceOver an element released below.
        self.publishFocus(null);

        // Release all NS objects
        for (self.wrappers[0..self.wrapper_count]) |*w| {
            if (w.ns_element) |ns| {
                releaseNSObject(ns);
                w.ns_element = null;
            }
            w.active = false;
            w.fingerprint = fingerprint_mod.Fingerprint.INVALID;
        }
        // Zero the slots any frame initialized before the pages go back (§21).
        if (self.wrappers.len > 0) {
            reservation.release(Fingerprint, self.fingerprint_to_slot, self.wrapper_count);
            reservation.release(Wrapper, self.wrappers, self.wrapper_count);
        }
        self.wrappers = &.{};
        self.fingerprint_to_slot = &.{};
        self.wrapper_count = 0;

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

        // Slots at or past `wrapper_count` were never allocated.
        std.debug.assert(self.wrapper_count <= self.wrappers.len);
        for (self.fingerprint_to_slot[0..self.wrapper_count], 0..) |slot_fp, i| {
            if (slot_fp.eql(fp)) return @intCast(i);
        }
        return null;
    }

    pub fn findOrAllocSlot(self: *Self, fp: fingerprint_mod.Fingerprint) ?u16 {
        // Assertion: fingerprint is valid
        std.debug.assert(fp.isValid());
        // Assertion: wrapper_count is bounded
        std.debug.assert(self.wrapper_count <= self.wrappers.len);

        // Try existing slot
        if (self.findSlotByFingerprint(fp)) |slot| return slot;

        // Find a free initialized slot, else initialize the next one.
        for (self.wrappers[0..self.wrapper_count], 0..) |*w, i| {
            if (!w.active) {
                self.fingerprint_to_slot[i] = fp;
                w.active = true; // Mark as allocated
                w.fingerprint = fp;
                return @intCast(i);
            }
        }
        if (self.wrapper_count < self.wrappers.len) {
            const slot = self.wrapper_count;
            self.wrappers[slot] = .{ .active = true, .fingerprint = fp };
            self.fingerprint_to_slot[slot] = fp;
            self.wrapper_count += 1;
            return slot;
        }

        // Every slot is taken; the caller reclaims stale ones.
        return null;
    }

    /// Free every wrapper whose element is not in `tree`'s current frame. One
    /// pass over the pool with an O(1) lookup each; it runs only when the pool
    /// is full, which needs a frame the bridge skipped.
    fn reclaimStale(self: *Self, tree: *const tree_mod.Tree) void {
        std.debug.assert(self.wrapper_count == self.wrappers.len);
        std.debug.assert(tree.count() <= self.wrappers.len);
        for (self.wrappers, 0..) |*w, i| {
            if (!w.active) continue;
            if (tree.findElementByFingerprint(w.fingerprint) != null) continue;
            w.invalidate();
            self.fingerprint_to_slot[i] = fingerprint_mod.Fingerprint.INVALID;
        }
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

/// Null restores AppKit's description of the role, so a reused wrapper never
/// keeps an earlier element's.
fn setAccessibilityRoleDescription(elem: objc.Object, description: ?[]const u8) void {
    std.debug.assert(elem.value != null);
    const text = description orelse {
        elem.msgSend(void, "setAccessibilityRoleDescription:", .{@as(objc.c.id, null)});
        return;
    };
    std.debug.assert(text.len > 0);
    const ns_text = createNSStringFromSlice(text) orelse return;
    defer releaseNSObject(ns_text);
    elem.msgSend(void, "setAccessibilityRoleDescription:", .{ns_text.value});
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

/// Set or, with null, clear the element's title (AXTitle).
fn setAccessibilityTitle(elem: objc.Object, title: ?[]const u8) void {
    std.debug.assert(elem.value != null);
    const text = title orelse {
        elem.msgSend(void, "setAccessibilityTitle:", .{@as(objc.c.id, null)});
        return;
    };
    std.debug.assert(text.len <= 65535);
    const ns_title = createNSStringFromSlice(text) orelse return;
    defer releaseNSObject(ns_title);
    elem.msgSend(void, "setAccessibilityTitle:", .{ns_title.value});
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

/// Whether a toggle is checked or an option chosen: both are radio buttons
/// or checkboxes to VoiceOver, which reads their value as the state. Null
/// for other roles.
fn toggleState(elem: *const tree_mod.Element) ?bool {
    return switch (elem.role) {
        .checkbox, .radio, .switch_ => elem.state.checked,
        .option => elem.state.selected,
        else => null,
    };
}

/// An option is a radio button to VoiceOver (see `Role.toNSRole`), named
/// as ARIA names it; other roles keep AppKit's description.
fn roleDescription(role: types.Role) ?[]const u8 {
    return if (role == .option) "option" else null;
}

fn setAccessibilityChecked(elem: objc.Object, checked: bool) void {
    std.debug.assert(elem.value != null);
    const NSNumber = objc.getClass("NSNumber") orelse return;
    const number: objc.c.id = NSNumber.msgSend(objc.c.id, "numberWithBool:", .{checked});
    std.debug.assert(number != null);
    elem.msgSend(void, "setAccessibilityValue:", .{number});
}

fn setAccessibilityRange(elem: objc.Object, min: f32, max: f32, now: f32) void {
    std.debug.assert(elem.value != null);
    std.debug.assert(min <= now);
    std.debug.assert(now <= max);
    const NSNumber = objc.getClass("NSNumber") orelse return;
    const values = [_]struct { selector: [:0]const u8, value: f32 }{
        .{ .selector = "setAccessibilityMinValue:", .value = min },
        .{ .selector = "setAccessibilityMaxValue:", .value = max },
        .{ .selector = "setAccessibilityValue:", .value = now },
    };
    for (values) |item| {
        const number: objc.c.id = NSNumber.msgSend(
            objc.c.id,
            "numberWithDouble:",
            .{@as(f64, item.value)},
        );
        std.debug.assert(number != null);
        elem.msgSend(void, item.selector, .{number});
    }
}

/// `NSAccessibilityOrientation`: unknown 0, vertical 1, horizontal 2.
fn setAccessibilityOrientation(elem: objc.Object, orientation: ?types.Orientation) void {
    std.debug.assert(elem.value != null);
    const value: c_long = if (orientation) |axis| switch (axis) {
        .vertical => 1,
        .horizontal => 2,
    } else 0;
    std.debug.assert(value <= 2);
    elem.msgSend(void, "setAccessibilityOrientation:", .{value});
}

/// Set a splitter's previous or next contents to `element` alone, or to
/// an empty array when there is none.
fn setAccessibilityContents(elem: objc.Object, selector: [:0]const u8, element: ?objc.Object) void {
    std.debug.assert(elem.value != null);
    std.debug.assert(selector.len > 0);
    const NSArray = objc.getClass("NSArray") orelse return;
    const contents: objc.c.id = if (element) |sibling|
        NSArray.msgSend(objc.c.id, "arrayWithObject:", .{sibling.value})
    else
        NSArray.msgSend(objc.c.id, "array", .{});
    std.debug.assert(contents != null);
    elem.msgSend(void, selector, .{contents});
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

/// Roles whose `selected` state VoiceOver reads, as UIA's Selection Item
/// and ARIA's `aria-selected` do.
fn isSelectable(role: types.Role) bool {
    return role == .option or role == .tab or role == .treeitem;
}

fn setAccessibilitySelected(elem: objc.Object, selected: bool) void {
    std.debug.assert(elem.value != null);
    elem.msgSend(void, "setAccessibilitySelected:", .{selected});
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
    } else if (toggleState(elem)) |on| {
        hasher.update(if (on) "checked" else "unchecked");
    } else if (elem.value_now) |now| {
        hasher.update("range:");
        hasher.update(std.mem.asBytes(&now));
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
    var bridge_impl = MacBridge.init(8, null, null);
    const b = bridge_impl.bridge();
    defer b.deinit();

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
    var bridge_impl = MacBridge.init(8, null, null);
    defer bridge_impl.bridge().deinit();

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

test "a full wrapper pool reclaims elements that left the tree in skipped frames" {
    // Goal: a pool of exactly the tree's capacity always holds the current
    // frame, even when removals were never synced (VoiceOver was off). Method:
    // fill a two-slot pool with two elements, build a frame of two others,
    // and check that the full pool reports no slot until the stale ones are
    // reclaimed, then takes both new elements without growing.
    const capacity: tree_mod.Capacity = .{
        .element_count_max = 2,
        .depth_max = 1,
        .announcement_count_max = 3,
    };
    var tree: tree_mod.Tree = undefined;
    try tree.initInPlace(&capacity);
    defer tree.deinit();
    var bridge_impl = MacBridge.init(capacity.element_count_max, null, null);
    defer bridge_impl.bridge().deinit();

    _ = bridge_impl.findOrAllocSlot(fingerprint_mod.compute(.button, "Old A", null, 0)).?;
    _ = bridge_impl.findOrAllocSlot(fingerprint_mod.compute(.button, "Old B", null, 1)).?;
    tree.beginFrame();
    for ([_][]const u8{ "New A", "New B" }) |name| {
        _ = tree.pushElement(.{ .role = .button, .name = name });
        tree.popElement();
    }
    tree.endFrame();
    const new_a = tree.getElement(0).?.fingerprint;
    try std.testing.expectEqual(@as(?u16, null), bridge_impl.findOrAllocSlot(new_a));
    bridge_impl.reclaimStale(&tree);
    try std.testing.expect(bridge_impl.findOrAllocSlot(new_a) != null);
    try std.testing.expect(bridge_impl.findOrAllocSlot(tree.getElement(1).?.fingerprint) != null);
    try std.testing.expectEqual(@as(u16, 2), bridge_impl.wrapper_count);
}

/// A bridge that syncs as if VoiceOver ran, with an element standing in for
/// the window and no screen conversion, plus a heap tree (~500 KiB).
const TestRig = struct {
    bridge_impl: MacBridge,
    tree: *tree_mod.Tree,
    root: objc.Object,

    fn init(rig: *TestRig) !void {
        rig.bridge_impl = MacBridge.init(tree_mod.Capacity.standard.element_count_max, null, null);
        rig.root = createNSAccessibilityElement().?;
        rig.bridge_impl.root_element = rig.root;
        rig.bridge_impl.voiceover_active = true;
        rig.tree = try std.testing.allocator.create(tree_mod.Tree);
        try rig.tree.initInPlace(&tree_mod.Capacity.standard);
    }

    fn deinit(rig: *TestRig) void {
        rig.bridge_impl.bridge().deinit();
        releaseNSObject(rig.root);
        rig.tree.deinit();
        std.testing.allocator.destroy(rig.tree);
    }

    /// `Bridge.syncFrame`'s order, without its screen-reader check.
    fn sync(rig: *TestRig) void {
        const b = rig.bridge_impl.bridge();
        b.syncDirty(rig.tree, rig.tree.getDirtyElements());
        const removed = rig.tree.getRemovedFingerprints();
        if (removed.len > 0) b.removeElements(removed);
    }

    fn leaf(rig: *TestRig, role: types.Role, name: []const u8, y: f32) void {
        const index = rig.tree.pushElement(.{ .role = role, .name = name });
        rig.tree.getElementMut(index).?.bounds = .{ .x = 5, .y = y, .width = 80, .height = 20 };
        rig.tree.popElement();
    }

    fn native(rig: *TestRig, role: types.Role, name: []const u8) objc.Object {
        var i: u16 = 0;
        while (i < rig.tree.count()) : (i += 1) {
            const elem = rig.tree.getElement(i).?;
            if (elem.role != role or !std.mem.eql(u8, elem.name.?, name)) continue;
            const slot = rig.bridge_impl.findSlotByFingerprint(elem.fingerprint).?;
            return rig.bridge_impl.wrappers[slot].ns_element.?;
        }
        unreachable;
    }
};

fn childCount(ns: objc.Object) usize {
    const children: objc.c.id = ns.msgSend(objc.c.id, "accessibilityChildren", .{});
    if (children == null) return 0;
    return objc.Object.fromId(children).msgSend(c_ulong, "count", .{});
}

test "mac bridge moves the frame of an element whose content did not change" {
    // Goal: a scroll or layout shift moves elements without changing their
    // content, so the tree marks nothing dirty; VoiceOver must still get the
    // new frames. Methodology: sync two frames in which a button moves and
    // another stays put, check the second had no dirty elements, and read
    // the native frames.
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    for ([_]f32{ 10, 70 }) |y| {
        rig.tree.beginFrame();
        rig.leaf(.button, "Submit", y);
        rig.leaf(.button, "Reset", 200);
        rig.tree.endFrame();
        rig.sync();
    }
    try std.testing.expectEqual(@as(usize, 0), rig.tree.getDirtyElements().len);
    const moved = rig.native(.button, "Submit").msgSend(NSRect, "accessibilityFrame", .{});
    try std.testing.expectEqual(@as(f64, 70), moved.origin.y);
    const still = rig.native(.button, "Reset").msgSend(NSRect, "accessibilityFrame", .{});
    try std.testing.expectEqual(@as(f64, 200), still.origin.y);
}

test "mac bridge clears the children of a reused wrapper that became a leaf" {
    // Goal: a pooled wrapper keeps its native object, so one reused for a
    // leaf must not keep the children it had. Methodology: a group with a
    // child takes the first slots; the next frame removes both, and the one
    // after adds a leaf button, which reuses the group's slot.
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    rig.tree.beginFrame();
    _ = rig.tree.pushElement(.{ .role = .group, .name = "Group" });
    rig.leaf(.button, "Inner", 10);
    rig.tree.popElement();
    rig.tree.endFrame();
    rig.sync();
    const group = rig.native(.group, "Group");
    try std.testing.expectEqual(@as(usize, 1), childCount(group));

    rig.tree.beginFrame();
    rig.leaf(.link, "Text", 10);
    rig.tree.endFrame();
    rig.sync();
    rig.tree.beginFrame();
    rig.leaf(.link, "Text", 10);
    rig.leaf(.button, "Leaf", 40);
    rig.tree.endFrame();
    rig.sync();
    const reused = rig.native(.button, "Leaf");
    try std.testing.expectEqual(group.value, reused.value);
    try std.testing.expectEqual(@as(usize, 0), childCount(reused));
}

test "mac bridge hangs a combobox's listbox beside it and reports chosen options" {
    // Goal: VoiceOver puts its cursor back on the child it last visited when
    // focus returns to a container, so a combobox holding its listbox sent
    // the cursor into the closed list; and it reads "selected" only from a
    // radio button's value. Methodology: sync a group holding an open
    // combobox with a chosen option, read the native tree, then close it.
    var rig: TestRig = undefined;
    try rig.init();
    defer rig.deinit();
    for ([_]bool{ true, false }) |open| {
        rig.tree.beginFrame();
        _ = rig.tree.pushElement(.{ .role = .group, .name = "Form" });
        _ = rig.tree.pushElement(.{
            .role = .combobox,
            .name = "Level",
            .state = .{ .expanded = open },
        });
        if (open) {
            _ = rig.tree.pushElement(.{ .role = .listbox, .name = "Level" });
            rig.leaf(.option, "One", 40);
            const chosen: types.State = .{ .selected = true };
            _ = rig.tree.pushElement(.{ .role = .option, .name = "Two", .state = chosen });
            rig.tree.popElement();
            rig.tree.popElement();
        }
        rig.tree.popElement();
        rig.tree.popElement();
        rig.tree.endFrame();
        rig.sync();
        const group = rig.native(.group, "Form");
        try std.testing.expectEqual(@as(usize, 0), childCount(rig.native(.combobox, "Level")));
        try std.testing.expectEqual(@as(usize, if (open) 2 else 1), childCount(group));
        if (!open) continue;
        const list = rig.native(.listbox, "Level");
        const list_parent: objc.c.id = list.msgSend(objc.c.id, "accessibilityParent", .{});
        try std.testing.expectEqual(group.value, list_parent);
        try expectOption(rig.native(.option, "One"), false);
        try expectOption(rig.native(.option, "Two"), true);
    }
}

fn expectOption(ns: objc.Object, selected: bool) !void {
    const role: objc.Object = ns.msgSend(objc.Object, "accessibilityRole", .{});
    const description: objc.Object = ns.msgSend(objc.Object, "accessibilityRoleDescription", .{});
    const value: objc.Object = ns.msgSend(objc.Object, "accessibilityValue", .{});
    const role_text = std.mem.span(role.msgSend([*:0]const u8, "UTF8String", .{}));
    const description_text = std.mem.span(description.msgSend([*:0]const u8, "UTF8String", .{}));
    try std.testing.expectEqualStrings("AXRadioButton", role_text);
    try std.testing.expectEqualStrings("option", description_text);
    try std.testing.expectEqual(selected, value.msgSend(bool, "boolValue", .{}));
}

test "role to ns role mapping" {
    // Verify key mappings exist and are reasonable
    try std.testing.expectEqualStrings("AXButton", types.Role.button.toNSRole());
    try std.testing.expectEqualStrings("AXCheckBox", types.Role.checkbox.toNSRole());
    try std.testing.expectEqualStrings("AXTextField", types.Role.textbox.toNSRole());
    try std.testing.expectEqualStrings("AXSlider", types.Role.slider.toNSRole());
    try std.testing.expectEqualStrings("AXDialog", types.Role.dialog.toNSRole());
}
