//! Web Accessibility Bridge using Shadow DOM + ARIA
//!
//! Provides screen reader support in browsers by maintaining a hidden
//! DOM tree that mirrors the accessibility tree. Screen readers read
//! the DOM; users see the canvas.
//!
//! Strategy:
//! - Hidden container using visually-hidden CSS technique
//! - ARIA roles/attributes for semantic meaning
//! - Batched DOM operations to minimize reflows
//! - Focus synchronization between DOM and Gooey
//! - Cannot reliably detect screen readers (use heuristics)

const std = @import("std");
const bridge_mod = @import("bridge.zig");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const Fingerprint = fingerprint_mod.Fingerprint;
const constants = @import("constants.zig");
const reservation = @import("../core/reservation.zig");

// Enable verbose init logging for debugging stack overflow issues
const verbose_init_logging = false;

// Direct extern for debug logging (avoid circular import)
extern "env" fn consoleLog(ptr: [*]const u8, len: u32) void;

fn wasmLog(comptime fmt: []const u8, args: anytype) void {
    if (!verbose_init_logging) return;
    var buf: [512]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch return;
    consoleLog(str.ptr, @intCast(str.len));
}

// ============================================================================
// JavaScript Imports (WASM externals)
// ============================================================================

/// Create the hidden accessibility container
extern "a11y" fn js_createContainer() u32;

/// Create a DOM element with the given ARIA role
extern "a11y" fn js_createElement(role_ptr: [*]const u8, role_len: u32) u32;

/// Remove a DOM element by ID
extern "a11y" fn js_removeElement(id: u32) void;

/// Set parent-child relationship in DOM
extern "a11y" fn js_setParent(child_id: u32, parent_id: u32) void;

/// Set an attribute on a DOM element
extern "a11y" fn js_setAttribute(
    id: u32,
    attr_ptr: [*]const u8,
    attr_len: u32,
    val_ptr: [*]const u8,
    val_len: u32,
) void;

/// Remove an attribute from a DOM element
extern "a11y" fn js_removeAttribute(id: u32, attr_ptr: [*]const u8, attr_len: u32) void;

/// Set bounds for touch exploration (stored as data attribute)
extern "a11y" fn js_setBounds(id: u32, x: f32, y: f32, w: f32, h: f32) void;

/// Focus a DOM element
extern "a11y" fn js_focus(id: u32) void;

/// Announce a message via live region
extern "a11y" fn js_announce(msg_ptr: [*]const u8, msg_len: u32, assertive: bool) void;

/// Check if screen reader might be active (heuristic)
extern "a11y" fn js_isScreenReaderHinted() bool;

/// Begin batching DOM operations
extern "a11y" fn js_beginBatch() void;

/// End batching and flush DOM operations
extern "a11y" fn js_endBatch() void;

// ============================================================================
// WebBridge
// ============================================================================

pub const WebBridge = struct {
    /// Container element ID (the hidden root div, 0 = not initialized)
    container_id: u32 = 0,

    /// Pool of DOM element IDs (0 = unused), `a11y.element_count_max` slots
    /// reserved at init from fresh pages, so an unused slot reads zero.
    dom_ids: []u32 = &.{},

    /// Map fingerprint -> slot for stable identity; meaningful below
    /// `slot_count` only.
    fingerprint_to_slot: []fingerprint_mod.Fingerprint = &.{},

    /// Slot usage tracking (false on fresh pages)
    slot_active: []bool = &.{},

    /// Slots ever taken; every slot at or past it is untouched.
    slot_count: u16 = 0,

    /// Currently focused slot (to prevent focus loops)
    focused_slot: ?u16 = null,

    /// Assume screen reader might be active (conservative default)
    /// Web can't reliably detect screen readers, so we default to true
    assumed_active: bool = true,

    /// Frame counter for periodic checks
    check_counter: u32 = 0,

    const Self = @This();

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize the web accessibility bridge in-place.
    /// Uses out-pointer pattern to avoid large stack copy in WASM.
    /// Creates the hidden container element in the DOM.
    /// Marked noinline to prevent stack accumulation in WASM builds.
    /// `element_count_max` is the tree's (`a11y.element_count_max`): stale
    /// slots are reclaimed before a new one is taken, so the frame's elements
    /// always fit. A failed reservation leaves the bridge inert and logged, as
    /// the Windows bridge does.
    pub noinline fn init(self: *Self, element_count_max: u16) void {
        std.debug.assert(self.container_id == 0); // Must be zero-initialized
        std.debug.assert(element_count_max > 0);
        self.reserveSlots(element_count_max) catch {
            std.log.err("accessibility: web bridge slot reservation failed", .{});
            self.assumed_active = false;
            return;
        };
        std.debug.assert(self.dom_ids.len == element_count_max);
        self.container_id = js_createContainer();
    }

    fn reserveSlots(self: *Self, element_count_max: u16) error{OutOfMemory}!void {
        const dom_ids = try reservation.reserve(u32, element_count_max);
        errdefer reservation.release(u32, dom_ids, 0);

        const fingerprints = try reservation.reserve(Fingerprint, element_count_max);
        errdefer reservation.release(Fingerprint, fingerprints, 0);

        self.slot_active = try reservation.reserve(bool, element_count_max);
        self.dom_ids = dom_ids;
        self.fingerprint_to_slot = fingerprints;
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

    /// The slot for `fingerprint`, claimed when it has none. When every slot
    /// is taken, some hold elements that left the tree in frames the bridge
    /// skipped; reclaiming them leaves at most the tree's elements, which the
    /// pool always holds.
    fn claimSlot(self: *Self, tree: *const tree_mod.Tree, fingerprint: Fingerprint) u16 {
        std.debug.assert(self.slot_count <= self.dom_ids.len);
        std.debug.assert(tree.count() <= self.dom_ids.len);
        if (self.findOrAllocSlot(fingerprint)) |slot| return slot;
        self.reclaimStale(tree);
        return self.findOrAllocSlot(fingerprint) orelse unreachable;
    }

    fn syncDirty(
        ptr: *anyopaque,
        tree: *const tree_mod.Tree,
        dirty: []const u16,
    ) void {
        const self = castSelf(ptr);

        // Assertion: dirty list is bounded
        std.debug.assert(dirty.len <= tree.count());
        // Assertion: tree count is valid
        std.debug.assert(tree.count() <= self.dom_ids.len);

        if (!self.assumed_active) return;
        if (dirty.len == 0) return;

        // Batch DOM operations for performance
        js_beginBatch();
        defer js_endBatch();

        for (dirty) |idx| {
            const elem = tree.getElement(idx) orelse continue;
            const slot = self.claimSlot(tree, elem.fingerprint);

            // Create DOM element if needed
            if (self.dom_ids[slot] == 0) {
                const role = elem.role.toAriaRole();
                self.dom_ids[slot] = js_createElement(role.ptr, @intCast(role.len));
            }

            const dom_id = self.dom_ids[slot];
            if (dom_id == 0) continue; // Failed to create

            // Update aria-label (name)
            if (elem.name) |name| {
                js_setAttribute(
                    dom_id,
                    "aria-label",
                    10,
                    name.ptr,
                    @intCast(name.len),
                );
            }

            // Update state attributes
            self.syncStateAttributes(dom_id, elem.state, elem.role);

            // Update value attributes (for sliders, progress, etc.)
            if (elem.value_min != null or elem.value_max != null or elem.value_now != null) {
                self.syncValueAttributes(dom_id, elem);
            }

            // Update relationship attributes (aria-labelledby, aria-describedby, aria-controls)
            if (elem.labelled_by != null or elem.described_by != null or elem.controls != null) {
                self.syncRelationshipAttributes(tree, dom_id, elem);
            }

            // Set parent relationship
            const parent_dom = self.resolveParentDomId(tree, elem.parent);
            js_setParent(dom_id, parent_dom);

            // Set bounds (for touch exploration on mobile)
            if (elem.bounds.width > 0 and elem.bounds.height > 0) {
                js_setBounds(
                    dom_id,
                    elem.bounds.x,
                    elem.bounds.y,
                    elem.bounds.width,
                    elem.bounds.height,
                );
            }

            // Update tracking state
            self.slot_active[slot] = true;
            self.fingerprint_to_slot[slot] = elem.fingerprint;
        }
    }

    /// Sync ARIA state attributes to DOM
    fn syncStateAttributes(self: *Self, dom_id: u32, state: types.State, role: types.Role) void {
        _ = self;

        // Assertion: dom_id must be valid
        std.debug.assert(dom_id != 0);
        // Assertion: role enum value is valid
        std.debug.assert(@backingInt(role) <= @backingInt(types.Role.none));

        // aria-disabled
        if (state.disabled) {
            js_setAttribute(dom_id, "aria-disabled", 13, "true", 4);
        } else {
            js_removeAttribute(dom_id, "aria-disabled", 13);
        }

        // aria-checked (for checkbox, radio, switch)
        if (role == .checkbox or role == .radio or role == .switch_) {
            if (state.checked) {
                js_setAttribute(dom_id, "aria-checked", 12, "true", 4);
            } else {
                js_setAttribute(dom_id, "aria-checked", 12, "false", 5);
            }
        }

        // aria-pressed (for toggle buttons)
        if (role == .button and state.pressed) {
            js_setAttribute(dom_id, "aria-pressed", 12, "true", 4);
        } else if (role == .button) {
            js_removeAttribute(dom_id, "aria-pressed", 12);
        }

        // aria-expanded (for disclosure widgets)
        if (role == .tree or role == .treeitem or role == .combobox or role == .menu) {
            if (state.expanded) {
                js_setAttribute(dom_id, "aria-expanded", 13, "true", 4);
            } else {
                js_setAttribute(dom_id, "aria-expanded", 13, "false", 5);
            }
        }

        // aria-selected (for selectable items)
        if (role == .option or role == .tab or role == .treeitem or role == .listitem) {
            if (state.selected) {
                js_setAttribute(dom_id, "aria-selected", 13, "true", 4);
            } else {
                js_setAttribute(dom_id, "aria-selected", 13, "false", 5);
            }
        }

        // aria-readonly
        if (state.readonly) {
            js_setAttribute(dom_id, "aria-readonly", 13, "true", 4);
        } else {
            js_removeAttribute(dom_id, "aria-readonly", 13);
        }

        // aria-required
        if (state.required) {
            js_setAttribute(dom_id, "aria-required", 13, "true", 4);
        } else {
            js_removeAttribute(dom_id, "aria-required", 13);
        }

        // aria-invalid
        if (state.invalid) {
            js_setAttribute(dom_id, "aria-invalid", 12, "true", 4);
        } else {
            js_removeAttribute(dom_id, "aria-invalid", 12);
        }

        // aria-busy
        if (state.busy) {
            js_setAttribute(dom_id, "aria-busy", 9, "true", 4);
        } else {
            js_removeAttribute(dom_id, "aria-busy", 9);
        }

        // aria-hidden
        if (state.hidden) {
            js_setAttribute(dom_id, "aria-hidden", 11, "true", 4);
        } else {
            js_removeAttribute(dom_id, "aria-hidden", 11);
        }

        // aria-haspopup (for combobox, menu triggers, etc.)
        if (state.has_popup) {
            // Determine popup type based on role
            const popup_type: []const u8 = switch (role) {
                .combobox => "listbox",
                .menu, .menubar => "menu",
                .tree => "tree",
                else => "true", // Generic popup
            };
            js_setAttribute(dom_id, "aria-haspopup", 12, popup_type.ptr, @intCast(popup_type.len));
        } else {
            js_removeAttribute(dom_id, "aria-haspopup", 12);
        }
    }

    /// Sync value-related ARIA attributes (for sliders, progress bars, etc.)
    fn syncValueAttributes(self: *Self, dom_id: u32, elem: *const tree_mod.Element) void {
        _ = self;
        var buf: [32]u8 = undefined;

        // Assertion: dom_id must be valid
        std.debug.assert(dom_id != 0);
        // Assertion: at least one value attribute should be set
        std.debug.assert(elem.value_min != null or elem.value_max != null or elem.value_now != null);

        if (elem.value_min) |min| {
            const str = std.fmt.bufPrint(&buf, "{d}", .{min}) catch return;
            js_setAttribute(dom_id, "aria-valuemin", 13, str.ptr, @intCast(str.len));
        }

        if (elem.value_max) |max| {
            const str = std.fmt.bufPrint(&buf, "{d}", .{max}) catch return;
            js_setAttribute(dom_id, "aria-valuemax", 13, str.ptr, @intCast(str.len));
        }

        if (elem.value_now) |now| {
            const str = std.fmt.bufPrint(&buf, "{d}", .{now}) catch return;
            js_setAttribute(dom_id, "aria-valuenow", 13, str.ptr, @intCast(str.len));
        }

        // A separator is horizontal unless it says otherwise (ARIA).
        if (elem.orientation) |orientation| {
            const axis = @tagName(orientation);
            js_setAttribute(dom_id, "aria-orientation", 16, axis.ptr, @intCast(axis.len));
        }

        // aria-valuetext from value field
        if (elem.value) |value| {
            js_setAttribute(dom_id, "aria-valuetext", 14, value.ptr, @intCast(value.len));
        }
    }

    /// Sync ARIA relationship attributes (aria-labelledby, aria-describedby, aria-controls)
    fn syncRelationshipAttributes(self: *Self, tree: *const tree_mod.Tree, dom_id: u32, elem: *const tree_mod.Element) void {
        // Assertion: dom_id must be valid
        std.debug.assert(dom_id != 0);

        var id_buf: [16]u8 = undefined;

        // aria-labelledby
        if (elem.labelled_by) |label_idx| {
            if (tree.getElement(label_idx)) |label_elem| {
                if (self.findSlotByFingerprint(label_elem.fingerprint)) |label_slot| {
                    const label_dom = self.dom_ids[label_slot];
                    if (label_dom != 0) {
                        const id_str = std.fmt.bufPrint(&id_buf, "a11y-{d}", .{label_dom}) catch return;
                        js_setAttribute(dom_id, "aria-labelledby", 15, id_str.ptr, @intCast(id_str.len));
                    }
                }
            }
        } else {
            js_removeAttribute(dom_id, "aria-labelledby", 15);
        }

        // aria-describedby
        if (elem.described_by) |desc_idx| {
            if (tree.getElement(desc_idx)) |desc_elem| {
                if (self.findSlotByFingerprint(desc_elem.fingerprint)) |desc_slot| {
                    const desc_dom = self.dom_ids[desc_slot];
                    if (desc_dom != 0) {
                        const id_str = std.fmt.bufPrint(&id_buf, "a11y-{d}", .{desc_dom}) catch return;
                        js_setAttribute(dom_id, "aria-describedby", 16, id_str.ptr, @intCast(id_str.len));
                    }
                }
            }
        } else {
            js_removeAttribute(dom_id, "aria-describedby", 16);
        }

        // aria-controls
        if (elem.controls) |ctrl_idx| {
            if (tree.getElement(ctrl_idx)) |ctrl_elem| {
                if (self.findSlotByFingerprint(ctrl_elem.fingerprint)) |ctrl_slot| {
                    const ctrl_dom = self.dom_ids[ctrl_slot];
                    if (ctrl_dom != 0) {
                        const id_str = std.fmt.bufPrint(&id_buf, "a11y-{d}", .{ctrl_dom}) catch return;
                        js_setAttribute(dom_id, "aria-controls", 13, id_str.ptr, @intCast(id_str.len));
                    }
                }
            }
        } else {
            js_removeAttribute(dom_id, "aria-controls", 13);
        }
    }

    /// Resolve parent element to DOM ID
    fn resolveParentDomId(self: *Self, tree: *const tree_mod.Tree, parent_idx: ?u16) u32 {
        // Assertion: container_id should be valid (non-zero or valid from JS)
        std.debug.assert(self.container_id != 0xFFFFFFFF); // Sentinel for error
        // Assertion: tree is valid
        std.debug.assert(tree.count() <= tree.elements.len);

        if (parent_idx) |pi| {
            if (tree.getElement(pi)) |parent_elem| {
                if (self.findSlotByFingerprint(parent_elem.fingerprint)) |ps| {
                    const parent_dom = self.dom_ids[ps];
                    if (parent_dom != 0) {
                        return parent_dom;
                    }
                }
            }
        }
        return self.container_id;
    }

    fn removeElements(ptr: *anyopaque, fingerprints: []const fingerprint_mod.Fingerprint) void {
        const self = castSelf(ptr);

        // Assertion: removal list bounded
        std.debug.assert(fingerprints.len <= self.dom_ids.len);
        // Assertion: container_id is valid
        std.debug.assert(self.container_id != 0xFFFFFFFF);

        if (fingerprints.len == 0) return;

        js_beginBatch();
        defer js_endBatch();

        for (fingerprints) |fp| {
            if (self.findSlotByFingerprint(fp)) |slot| {
                if (self.dom_ids[slot] != 0) {
                    js_removeElement(self.dom_ids[slot]);
                    self.dom_ids[slot] = 0;
                }
                self.slot_active[slot] = false;
                self.fingerprint_to_slot[slot] = fingerprint_mod.Fingerprint.INVALID;
            }
        }
    }

    fn announce_(ptr: *anyopaque, message: []const u8, live: types.Live) void {
        _ = ptr;

        // Assertion: message is bounded (reasonable limit)
        std.debug.assert(message.len <= 4096);
        // Assertion: live level is valid
        std.debug.assert(@backingInt(live) <= @backingInt(types.Live.assertive));

        if (live == .off) return;

        js_announce(message.ptr, @intCast(message.len), live == .assertive);
    }

    fn focusChanged(ptr: *anyopaque, tree: *const tree_mod.Tree, idx: ?u16) void {
        const self = castSelf(ptr);

        // Assertion: tree is valid
        std.debug.assert(tree.count() <= tree.elements.len);
        // Assertion: idx is valid if present
        std.debug.assert(idx == null or idx.? < tree.count());

        if (idx) |i| {
            if (tree.getElement(i)) |elem| {
                if (self.findSlotByFingerprint(elem.fingerprint)) |slot| {
                    const dom_id = self.dom_ids[slot];
                    // Prevent focus loops
                    if (dom_id != 0 and self.focused_slot != slot) {
                        js_focus(dom_id);
                        self.focused_slot = slot;
                    }
                }
            }
        } else {
            self.focused_slot = null;
        }
    }

    fn isActive(ptr: *anyopaque) bool {
        const self = castSelf(ptr);

        // Periodic check (not every frame)
        self.check_counter += 1;
        if (self.check_counter >= constants.SCREEN_READER_CHECK_INTERVAL) {
            self.check_counter = 0;
            // Use heuristic - can't reliably detect screen readers on web
            // An inert bridge (its reservation failed) never syncs.
            self.assumed_active = self.dom_ids.len > 0 and js_isScreenReaderHinted();
        }

        return self.assumed_active;
    }

    /// DOM elements are cleaned up by the browser when the page unloads; the
    /// slots any frame took are zeroed before their pages go back (§21).
    fn deinit_(ptr: *anyopaque) void {
        const self = castSelf(ptr);
        if (self.dom_ids.len == 0) return;
        reservation.release(bool, self.slot_active, self.slot_count);
        reservation.release(Fingerprint, self.fingerprint_to_slot, self.slot_count);
        reservation.release(u32, self.dom_ids, self.slot_count);
        self.dom_ids = &.{};
        self.fingerprint_to_slot = &.{};
        self.slot_active = &.{};
        self.slot_count = 0;
    }

    // =========================================================================
    // Slot Management
    // =========================================================================

    /// Find slot by fingerprint (linear search is fine for typical counts)
    fn findSlotByFingerprint(self: *Self, fp: fingerprint_mod.Fingerprint) ?u16 {
        // Assertion: fingerprint should be valid when searching
        std.debug.assert(fp.isValid());

        std.debug.assert(self.slot_count <= self.fingerprint_to_slot.len);
        for (self.fingerprint_to_slot[0..self.slot_count], 0..) |slot_fp, i| {
            if (slot_fp.eql(fp)) return @intCast(i);
        }
        return null;
    }

    /// Find existing slot or allocate a new one
    fn findOrAllocSlot(self: *Self, fp: fingerprint_mod.Fingerprint) ?u16 {
        // Assertion: fingerprint must be valid
        std.debug.assert(fp.isValid());

        // First, try to find existing slot
        if (self.findSlotByFingerprint(fp)) |slot| return slot;

        // Find an inactive slot, else take the next untouched one.
        for (self.slot_active[0..self.slot_count], 0..) |active, i| {
            if (!active) {
                self.fingerprint_to_slot[i] = fp;
                return @intCast(i);
            }
        }
        if (self.slot_count < self.dom_ids.len) {
            const slot = self.slot_count;
            std.debug.assert(self.dom_ids[slot] == 0); // Fresh pages.
            self.fingerprint_to_slot[slot] = fp;
            self.slot_count += 1;
            return slot;
        }

        // Every slot is taken; the caller reclaims stale ones.
        return null;
    }

    /// Remove every slot's element that is not in `tree`'s current frame.
    /// One pass with an O(1) lookup each; it runs only when the pool is full,
    /// which needs a frame the bridge skipped.
    fn reclaimStale(self: *Self, tree: *const tree_mod.Tree) void {
        std.debug.assert(self.slot_count == self.dom_ids.len);
        std.debug.assert(tree.count() <= self.dom_ids.len);
        for (self.fingerprint_to_slot, 0..) |fp, i| {
            if (!self.slot_active[i]) continue;
            if (tree.findElementByFingerprint(fp) != null) continue;
            if (self.dom_ids[i] != 0) js_removeElement(self.dom_ids[i]);
            self.dom_ids[i] = 0;
            self.slot_active[i] = false;
            self.fingerprint_to_slot[i] = fingerprint_mod.Fingerprint.INVALID;
        }
    }

    fn castSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }
};

// ============================================================================
// Compile-time Assertions (per CLAUDE.md)
// ============================================================================

comptime {
    // The slots are reserved slices, so the bridge itself stays a few dozen
    // bytes and needs no in-place initialization on the WASM stack.
    std.debug.assert(@sizeOf(WebBridge) < 256);
}

// ============================================================================
// Tests (run on non-WASM targets)
// ============================================================================

test "web bridge slot management" {
    // Note: Can't test actual JS calls, but can test slot logic
    const fp1 = fingerprint_mod.compute(.button, "Test1", null, 0);
    const fp2 = fingerprint_mod.compute(.button, "Test2", null, 1);

    // Test fingerprint equality used in slot lookup
    try std.testing.expect(!fp1.eql(fp2));
    try std.testing.expect(fp1.eql(fp1));
}

test "aria role mapping" {
    // Test that roles map to valid ARIA strings
    try std.testing.expectEqualStrings("button", types.Role.button.toAriaRole());
    try std.testing.expectEqualStrings("checkbox", types.Role.checkbox.toAriaRole());
    try std.testing.expectEqualStrings("slider", types.Role.slider.toAriaRole());
    try std.testing.expectEqualStrings("textbox", types.Role.textbox.toAriaRole());
    try std.testing.expectEqualStrings("dialog", types.Role.dialog.toAriaRole());
}

test "state flag combinations" {
    const state1 = types.State{ .disabled = true, .checked = true };
    const state2 = types.State{ .focused = true, .expanded = true };

    try std.testing.expect(state1.disabled);
    try std.testing.expect(state1.checked);
    try std.testing.expect(!state1.focused);

    try std.testing.expect(state2.focused);
    try std.testing.expect(state2.expanded);
    try std.testing.expect(!state2.disabled);
}

test "has_popup state for combobox" {
    // Test that has_popup works with combobox role (used by Select component)
    const combobox_state = types.State{ .expanded = true, .has_popup = true };

    try std.testing.expect(combobox_state.has_popup);
    try std.testing.expect(combobox_state.expanded);
    try std.testing.expect(!combobox_state.disabled);

    // Verify role-based popup type mapping
    try std.testing.expectEqualStrings("combobox", types.Role.combobox.toAriaRole());
    try std.testing.expectEqualStrings("menu", types.Role.menu.toAriaRole());
    try std.testing.expectEqualStrings("tree", types.Role.tree.toAriaRole());
}
