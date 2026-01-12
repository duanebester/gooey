//! Linux Accessibility Bridge using AT-SPI2 over D-Bus
//!
//! Provides Orca and other screen reader support by implementing the AT-SPI2
//! protocol over D-Bus. Uses a pooled object approach for zero-allocation
//! after initialization.
//!
//! Strategy:
//! - Register application with AT-SPI registry once at init
//! - Create D-Bus object per element (pooled, reused by fingerprint)
//! - Use property cache - screen readers query us, we don't push entire tree
//! - Emit signals only for changes (PropertyChange, StateChanged)
//!
//! Key insight: AT-SPI2 is pull-based. Screen readers cache our tree
//! and we notify them of changes. We don't re-send the whole tree.

const std = @import("std");
const builtin = @import("builtin");
const bridge_mod = @import("bridge.zig");
const tree_mod = @import("tree.zig");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const constants = @import("constants.zig");

// Only compile D-Bus integration on Linux
const dbus = if (builtin.os.tag == .linux) @import("../platform/linux/dbus.zig") else struct {};

// ============================================================================
// AT-SPI2 Constants
// ============================================================================

/// AT-SPI2 bus name
const ATSPI_BUS_NAME = "org.a11y.Bus";

/// AT-SPI2 registry interface
const ATSPI_REGISTRY_INTERFACE = "org.a11y.atspi.Registry";

/// AT-SPI2 accessible interface
const ATSPI_ACCESSIBLE_INTERFACE = "org.a11y.atspi.Accessible";

/// AT-SPI2 event interface for signals
const ATSPI_EVENT_OBJECT_INTERFACE = "org.a11y.atspi.Event.Object";

/// AT-SPI2 status interface for checking if a11y is enabled
const ATSPI_STATUS_INTERFACE = "org.a11y.Status";

/// Registry path
const ATSPI_REGISTRY_PATH = "/org/a11y/atspi/registry";

/// Our application base path
const APP_A11Y_PATH = "/org/gooey/a11y";

/// Maximum pending signals per frame
const MAX_PENDING_SIGNALS: usize = 64;

/// D-Bus timeout for method calls (ms)
const DBUS_TIMEOUT_MS: c_int = 100;

/// Frame interval for AT-SPI status checks (every ~1 second at 60fps)
const ATSPI_CHECK_INTERVAL: u32 = 60;

// ============================================================================
// LinuxBridge
// ============================================================================

pub const LinuxBridge = struct {
    /// D-Bus connection (session bus for AT-SPI2)
    connection: ?Connection = null,

    /// Our unique bus name (assigned by D-Bus)
    bus_name_buf: [64]u8 = undefined,
    bus_name_len: u8 = 0,

    /// Pool of AT-SPI2 accessible objects (static allocation)
    objects: [constants.MAX_ELEMENTS]A11yObject = [_]A11yObject{A11yObject{}} ** constants.MAX_ELEMENTS,
    object_count: u16 = 0,

    /// Map fingerprint -> object slot for stable identity
    /// Linear search is fine for typical element counts (<500)
    fingerprint_to_slot: [constants.MAX_ELEMENTS]fingerprint_mod.Fingerprint =
        [_]fingerprint_mod.Fingerprint{fingerprint_mod.Fingerprint.INVALID} ** constants.MAX_ELEMENTS,

    /// Is AT-SPI2 active and a screen reader running?
    atspi_active: bool = false,

    /// Frame counter for periodic status checks
    check_counter: u32 = 0,

    /// Pending signals to emit (batched for performance)
    pending_signals: [MAX_PENDING_SIGNALS]PendingSignal = undefined,
    signal_count: u8 = 0,

    /// Currently focused element slot (for focus tracking)
    focused_slot: ?u16 = null,

    /// Platform-specific connection type
    const Connection = if (builtin.os.tag == .linux) dbus.Connection else void;

    const Self = @This();

    // =========================================================================
    // A11yObject - AT-SPI2 Accessible Object
    // =========================================================================

    const A11yObject = struct {
        /// D-Bus object path buffer: /org/gooey/a11y/elem/{slot}
        path_buf: [48]u8 = undefined,
        path_len: u8 = 0,

        /// Cached element properties (for D-Bus queries and change detection)
        role: types.Role = .none,
        name_buf: [128]u8 = undefined,
        name_len: u8 = 0,
        description_buf: [256]u8 = undefined,
        description_len: u16 = 0,
        state: types.State = .{},

        /// Value for range controls (sliders, progress bars)
        value_now: f32 = 0,
        value_min: f32 = 0,
        value_max: f32 = 100,

        /// Identity
        fingerprint: fingerprint_mod.Fingerprint = fingerprint_mod.Fingerprint.INVALID,

        /// Is this slot currently in use?
        active: bool = false,

        /// Parent slot (for tree structure)
        parent_slot: ?u16 = null,

        /// Get the D-Bus object path
        pub fn objectPath(self: *const A11yObject) []const u8 {
            std.debug.assert(self.path_len > 0);
            std.debug.assert(self.path_len <= self.path_buf.len);
            return self.path_buf[0..self.path_len];
        }

        /// Get the cached name
        pub fn name(self: *const A11yObject) []const u8 {
            return self.name_buf[0..self.name_len];
        }

        /// Get the cached description
        pub fn description(self: *const A11yObject) []const u8 {
            return self.description_buf[0..self.description_len];
        }

        /// Update object from accessibility tree element
        /// Returns bitmask of what changed for signal emission
        pub fn update(self: *A11yObject, elem: *const tree_mod.Element, slot: u16) ChangeFlags {
            // Assertion: element must have valid fingerprint
            std.debug.assert(elem.fingerprint.isValid());
            // Assertion: slot is within bounds
            std.debug.assert(slot < constants.MAX_ELEMENTS);

            var changes = ChangeFlags{};

            // Set object path if not already set
            if (self.path_len == 0) {
                const written = std.fmt.bufPrint(&self.path_buf, "{s}/elem/{d}", .{
                    APP_A11Y_PATH,
                    slot,
                }) catch {
                    return changes;
                };
                self.path_len = @intCast(written.len);
            }

            // Detect role change
            if (self.role != elem.role) {
                self.role = elem.role;
                changes.role_changed = true;
            }

            // Detect name change
            if (elem.name) |new_name| {
                const current = self.name();
                if (!std.mem.eql(u8, current, new_name)) {
                    const len = @min(new_name.len, self.name_buf.len - 1);
                    @memcpy(self.name_buf[0..len], new_name[0..len]);
                    self.name_len = @intCast(len);
                    changes.name_changed = true;
                }
            } else if (self.name_len > 0) {
                self.name_len = 0;
                changes.name_changed = true;
            }

            // Detect description change
            if (elem.description) |new_desc| {
                const current = self.description();
                if (!std.mem.eql(u8, current, new_desc)) {
                    const len = @min(new_desc.len, self.description_buf.len - 1);
                    @memcpy(self.description_buf[0..len], new_desc[0..len]);
                    self.description_len = @intCast(len);
                    changes.description_changed = true;
                }
            } else if (self.description_len > 0) {
                self.description_len = 0;
                changes.description_changed = true;
            }

            // Detect state change
            if (!self.state.eql(elem.state)) {
                changes.state_changed = true;
                changes.old_state = self.state;
                self.state = elem.state;
            }

            // Detect value change (for range controls)
            if (elem.value_now) |v| {
                if (self.value_now != v) {
                    self.value_now = v;
                    changes.value_changed = true;
                }
            }
            if (elem.value_min) |v| self.value_min = v;
            if (elem.value_max) |v| self.value_max = v;

            self.fingerprint = elem.fingerprint;
            self.active = true;

            return changes;
        }

        /// Invalidate this object (mark for reuse)
        pub fn invalidate(self: *A11yObject) void {
            self.active = false;
            self.fingerprint = fingerprint_mod.Fingerprint.INVALID;
            self.name_len = 0;
            self.description_len = 0;
            self.path_len = 0;
            self.parent_slot = null;
        }
    };

    /// Flags indicating what properties changed during an update
    const ChangeFlags = struct {
        role_changed: bool = false,
        name_changed: bool = false,
        description_changed: bool = false,
        state_changed: bool = false,
        value_changed: bool = false,
        old_state: types.State = .{},
    };

    // =========================================================================
    // PendingSignal - Batched Signal Queue
    // =========================================================================

    const PendingSignal = struct {
        slot: u16,
        signal_type: SignalType,
        detail: SignalDetail = .{},

        const SignalType = enum(u8) {
            property_change_name,
            property_change_description,
            property_change_value,
            state_changed_focused,
            state_changed_checked,
            state_changed_expanded,
            state_changed_selected,
            state_changed_enabled,
            children_changed_add,
            children_changed_remove,
            focus_gained,
            announcement,
        };

        const SignalDetail = struct {
            /// For state changes: true = gained, false = lost
            state_value: bool = false,
            /// For announcements: live region priority
            live: types.Live = .polite,
        };
    };

    // =========================================================================
    // Initialization
    // =========================================================================

    /// Initialize the Linux AT-SPI2 accessibility bridge
    /// Connects to D-Bus and registers with AT-SPI2 registry if available
    pub fn init() Self {
        var self = Self{};

        if (builtin.os.tag != .linux) {
            return self;
        }

        // Try to connect to session bus
        self.connection = Connection.connectSession() catch |err| {
            std.log.warn("A11y: Failed to connect to D-Bus session bus: {}", .{err});
            return self;
        };

        // Store our unique bus name
        if (self.connection) |*conn| {
            if (conn.getUniqueName()) |name| {
                const len = @min(name.len, self.bus_name_buf.len - 1);
                @memcpy(self.bus_name_buf[0..len], name[0..len]);
                self.bus_name_len = @intCast(len);
            }
        }

        // Check if AT-SPI2 is enabled
        self.atspi_active = self.checkAtSpiActive();

        if (self.atspi_active) {
            self.registerWithAtSpi() catch |err| {
                std.log.warn("A11y: Failed to register with AT-SPI2: {}", .{err});
                self.atspi_active = false;
            };
        }

        return self;
    }

    /// Get the Bridge interface (vtable pattern for polymorphism)
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

        // Assertions
        std.debug.assert(dirty.len <= constants.MAX_ELEMENTS);
        std.debug.assert(self.signal_count == 0); // Should be flushed from previous frame

        if (!self.atspi_active) return;
        if (dirty.len == 0) return;

        // Reset signal queue
        self.signal_count = 0;

        // Sync each dirty element
        for (dirty) |idx| {
            self.syncElement(tree, idx);
        }

        // Emit all batched signals
        self.emitPendingSignals();
    }

    /// Sync a single element to its AT-SPI2 object
    fn syncElement(self: *Self, tree: *const tree_mod.Tree, idx: u16) void {
        // Assertion: idx is valid
        std.debug.assert(idx < constants.MAX_ELEMENTS);

        const elem = tree.getElement(idx) orelse return;

        // Skip non-accessible elements
        if (!elem.isAccessible()) return;

        // Find or allocate a slot for this element
        const slot = self.findOrAllocSlot(elem.fingerprint) orelse {
            std.log.warn("A11y: Object pool exhausted", .{});
            return;
        };

        const obj = &self.objects[slot];
        const was_new = !obj.active;

        // Update the object and get change flags
        const changes = obj.update(elem, slot);

        // Queue signals for changes
        if (was_new) {
            self.queueSignal(slot, .children_changed_add, .{});
        } else {
            if (changes.name_changed) {
                self.queueSignal(slot, .property_change_name, .{});
            }
            if (changes.description_changed) {
                self.queueSignal(slot, .property_change_description, .{});
            }
            if (changes.value_changed) {
                self.queueSignal(slot, .property_change_value, .{});
            }
            if (changes.state_changed) {
                self.queueStateChangeSignals(slot, changes.old_state, obj.state);
            }
        }
    }

    /// Queue signals for state changes (focused, checked, etc.)
    fn queueStateChangeSignals(
        self: *Self,
        slot: u16,
        old: types.State,
        new: types.State,
    ) void {
        // Assertion: slot is valid
        std.debug.assert(slot < constants.MAX_ELEMENTS);

        if (old.focused != new.focused) {
            self.queueSignal(slot, .state_changed_focused, .{ .state_value = new.focused });
        }
        if (old.checked != new.checked) {
            self.queueSignal(slot, .state_changed_checked, .{ .state_value = new.checked });
        }
        if (old.expanded != new.expanded) {
            self.queueSignal(slot, .state_changed_expanded, .{ .state_value = new.expanded });
        }
        if (old.selected != new.selected) {
            self.queueSignal(slot, .state_changed_selected, .{ .state_value = new.selected });
        }
        if (old.disabled != new.disabled) {
            self.queueSignal(slot, .state_changed_enabled, .{ .state_value = !new.disabled });
        }
    }

    fn removeElements(
        ptr: *anyopaque,
        fingerprints: []const fingerprint_mod.Fingerprint,
    ) void {
        const self = castSelf(ptr);

        // Assertion: fingerprints bounded
        std.debug.assert(fingerprints.len <= constants.MAX_ELEMENTS);

        if (!self.atspi_active) return;

        for (fingerprints) |fp| {
            if (self.findSlotByFingerprint(fp)) |slot| {
                // Queue removal signal
                self.queueSignal(slot, .children_changed_remove, .{});

                // Invalidate the object
                self.objects[slot].invalidate();
                self.fingerprint_to_slot[slot] = fingerprint_mod.Fingerprint.INVALID;

                // Clear focus if this was the focused element
                if (self.focused_slot == slot) {
                    self.focused_slot = null;
                }
            }
        }

        self.emitPendingSignals();
    }

    fn announce_(
        ptr: *anyopaque,
        message: []const u8,
        live: types.Live,
    ) void {
        const self = castSelf(ptr);

        // Assertions
        std.debug.assert(message.len <= 1024);
        std.debug.assert(live == .polite or live == .assertive or live == .off);

        if (!self.atspi_active) return;
        if (live == .off) return;

        // Emit announcement signal
        self.emitAnnouncementSignal(message, live);
    }

    fn focusChanged(
        ptr: *anyopaque,
        tree: *const tree_mod.Tree,
        idx: ?u16,
    ) void {
        const self = castSelf(ptr);

        // Assertion: tree is valid
        std.debug.assert(tree.count() <= constants.MAX_ELEMENTS);

        if (!self.atspi_active) return;

        // Clear previous focus
        if (self.focused_slot) |old_slot| {
            self.queueSignal(old_slot, .state_changed_focused, .{ .state_value = false });
        }

        // Set new focus
        if (idx) |i| {
            if (tree.getElement(i)) |elem| {
                if (self.findSlotByFingerprint(elem.fingerprint)) |slot| {
                    self.focused_slot = slot;
                    self.queueSignal(slot, .state_changed_focused, .{ .state_value = true });
                    self.queueSignal(slot, .focus_gained, .{});
                }
            }
        } else {
            self.focused_slot = null;
        }

        self.emitPendingSignals();
    }

    fn isActive(ptr: *anyopaque) bool {
        const self = castSelf(ptr);

        // Periodic check for AT-SPI status
        self.check_counter +%= 1;
        if (self.check_counter >= ATSPI_CHECK_INTERVAL) {
            self.check_counter = 0;
            self.atspi_active = self.checkAtSpiActive();
        }

        return self.atspi_active;
    }

    fn deinit_(ptr: *anyopaque) void {
        const self = castSelf(ptr);

        // Unregister from AT-SPI if we were registered
        if (self.atspi_active) {
            self.unregisterFromAtSpi();
        }

        // Close D-Bus connection
        if (self.connection) |*conn| {
            conn.deinit();
            self.connection = null;
        }
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

    fn findOrAllocSlot(self: *Self, fp: fingerprint_mod.Fingerprint) ?u16 {
        // Assertion: fingerprint is valid
        std.debug.assert(fp.isValid());

        // First check if we already have a slot for this fingerprint
        if (self.findSlotByFingerprint(fp)) |slot| return slot;

        // Find an inactive slot to reuse
        for (&self.objects, 0..) |*obj, i| {
            if (!obj.active) {
                obj.active = true;
                self.fingerprint_to_slot[i] = fp;
                if (self.object_count <= i) {
                    self.object_count = @intCast(i + 1);
                }
                return @intCast(i);
            }
        }
        return null;
    }

    // =========================================================================
    // Signal Queue Management
    // =========================================================================

    fn queueSignal(
        self: *Self,
        slot: u16,
        signal_type: PendingSignal.SignalType,
        detail: PendingSignal.SignalDetail,
    ) void {
        // Assertion: slot valid
        std.debug.assert(slot < constants.MAX_ELEMENTS);

        if (self.signal_count >= MAX_PENDING_SIGNALS) {
            // Queue full - emit immediately to make room
            self.emitPendingSignals();
        }

        self.pending_signals[self.signal_count] = .{
            .slot = slot,
            .signal_type = signal_type,
            .detail = detail,
        };
        self.signal_count += 1;
    }

    /// Emit all pending signals over D-Bus
    fn emitPendingSignals(self: *Self) void {
        if (builtin.os.tag != .linux) return;

        const conn = &(self.connection orelse return);

        var i: u8 = 0;
        while (i < self.signal_count) : (i += 1) {
            const sig = self.pending_signals[i];
            self.emitSignal(conn, sig);
        }

        // Flush D-Bus connection to ensure signals are sent
        conn.flush();

        self.signal_count = 0;
    }

    /// Emit a single AT-SPI2 signal
    fn emitSignal(self: *Self, conn: *Connection, sig: PendingSignal) void {
        // Assertion: slot is valid
        std.debug.assert(sig.slot < constants.MAX_ELEMENTS);

        const obj = &self.objects[sig.slot];

        // Handle children_changed signals early - they don't need the object path
        // (they emit on APP_A11Y_PATH) and for remove signals the object may
        // already be invalidated
        if (sig.signal_type == .children_changed_remove) {
            self.emitChildrenChangedSignal(conn, "remove", sig.slot);
            return;
        }
        if (sig.signal_type == .children_changed_add) {
            self.emitChildrenChangedSignal(conn, "add", sig.slot);
            return;
        }

        if (!obj.active) return;

        // Get object path - required for remaining signal types
        if (obj.path_len == 0) return;
        const path = obj.objectPath();

        // Build signal based on type
        switch (sig.signal_type) {
            .property_change_name => {
                self.emitPropertyChangeSignal(conn, path, "Name", obj.name());
            },
            .property_change_description => {
                self.emitPropertyChangeSignal(conn, path, "Description", obj.description());
            },
            .property_change_value => {
                self.emitValueChangeSignal(conn, path, obj.value_now);
            },
            .state_changed_focused => {
                self.emitStateChangeSignal(conn, path, "focused", sig.detail.state_value);
            },
            .state_changed_checked => {
                self.emitStateChangeSignal(conn, path, "checked", sig.detail.state_value);
            },
            .state_changed_expanded => {
                self.emitStateChangeSignal(conn, path, "expanded", sig.detail.state_value);
            },
            .state_changed_selected => {
                self.emitStateChangeSignal(conn, path, "selected", sig.detail.state_value);
            },
            .state_changed_enabled => {
                self.emitStateChangeSignal(conn, path, "enabled", sig.detail.state_value);
            },
            .children_changed_add, .children_changed_remove => {
                // Already handled above
                unreachable;
            },
            .focus_gained => {
                self.emitFocusSignal(conn, path);
            },
            .announcement => {
                // Handled separately via emitAnnouncementSignal
            },
        }
    }

    // =========================================================================
    // D-Bus Signal Emission Helpers
    // =========================================================================

    /// Helper to create a null-terminated path for D-Bus
    fn makePathZ(self: *Self, path: []const u8) ?[:0]const u8 {
        // Use the object's path_buf which is already formatted
        _ = self;
        if (path.len == 0 or path.len >= 47) return null;
        // The path comes from A11yObject.path_buf which has space for null terminator
        // We need to verify it's null-terminated
        const ptr: [*]const u8 = path.ptr;
        if (ptr[path.len] == 0) {
            return ptr[0..path.len :0];
        }
        return null;
    }

    fn emitPropertyChangeSignal(
        self: *Self,
        conn: *Connection,
        path: []const u8,
        property: []const u8,
        value: []const u8,
    ) void {
        if (builtin.os.tag != .linux) return;

        // Build signal name from property: "PropertyChange:accessible-name"
        var signal_detail_buf: [64]u8 = undefined;
        const detail_name = if (std.mem.eql(u8, property, "Name"))
            "accessible-name"
        else if (std.mem.eql(u8, property, "Description"))
            "accessible-description"
        else
            "accessible-value";

        const signal_name = std.fmt.bufPrintZ(&signal_detail_buf, "PropertyChange:{s}", .{detail_name}) catch return;
        _ = signal_name;

        // Get null-terminated path
        const path_z = self.makePathZ(path) orelse return;

        // Create AT-SPI2 PropertyChange signal
        // Signal: org.a11y.atspi.Event.Object::PropertyChange
        var msg = dbus.Message.newSignal(
            path_z,
            ATSPI_EVENT_OBJECT_INTERFACE,
            "PropertyChange",
        ) catch return;
        defer msg.deinit();

        // AT-SPI2 event arguments: (siiv(so))
        // s: detail (property name like "accessible-name")
        // i: detail1 (unused, 0)
        // i: detail2 (unused, 0)
        // v: any_data (the new value as variant)
        // (so): sender reference (bus_name, path)
        var iter = msg.iterInitAppend();

        // Append detail string
        var detail_z_buf: [32]u8 = undefined;
        const detail_z = std.fmt.bufPrintZ(&detail_z_buf, "{s}", .{detail_name}) catch return;
        if (!iter.appendString(detail_z)) return;

        // Append detail1 (0)
        if (!iter.appendInt32(0)) return;

        // Append detail2 (0)
        if (!iter.appendInt32(0)) return;

        // Append value as variant (string)
        var value_z_buf: [256]u8 = undefined;
        const value_z = std.fmt.bufPrintZ(&value_z_buf, "{s}", .{value}) catch return;
        if (!iter.appendVariantString(value_z)) return;

        // Send signal
        conn.send(&msg) catch return;
    }

    fn emitValueChangeSignal(
        self: *Self,
        conn: *Connection,
        path: []const u8,
        value: f32,
    ) void {
        if (builtin.os.tag != .linux) return;

        const path_z = self.makePathZ(path) orelse return;

        // Create value change signal
        var msg = dbus.Message.newSignal(
            path_z,
            ATSPI_EVENT_OBJECT_INTERFACE,
            "PropertyChange",
        ) catch return;
        defer msg.deinit();

        var iter = msg.iterInitAppend();

        // Property name
        if (!iter.appendString("accessible-value")) return;

        // detail1, detail2
        if (!iter.appendInt32(0)) return;
        if (!iter.appendInt32(0)) return;

        // Value as variant (double)
        if (!iter.appendVariantDouble(@floatCast(value))) return;

        conn.send(&msg) catch return;
    }

    fn emitStateChangeSignal(
        self: *Self,
        conn: *Connection,
        path: []const u8,
        state_name: []const u8,
        state_value: bool,
    ) void {
        if (builtin.os.tag != .linux) return;

        const path_z = self.makePathZ(path) orelse return;

        // Create AT-SPI2 StateChanged signal
        var msg = dbus.Message.newSignal(
            path_z,
            ATSPI_EVENT_OBJECT_INTERFACE,
            "StateChanged",
        ) catch return;
        defer msg.deinit();

        var iter = msg.iterInitAppend();

        // State name (e.g., "focused", "checked")
        var state_z_buf: [32]u8 = undefined;
        const state_z = std.fmt.bufPrintZ(&state_z_buf, "{s}", .{state_name}) catch return;
        if (!iter.appendString(state_z)) return;

        // detail1: 1 if state is now active, 0 if inactive
        if (!iter.appendInt32(if (state_value) 1 else 0)) return;

        // detail2: unused
        if (!iter.appendInt32(0)) return;

        // any_data as variant (empty string)
        if (!iter.appendVariantString("")) return;

        conn.send(&msg) catch return;
    }

    fn emitChildrenChangedSignal(
        _: *Self,
        conn: *Connection,
        change_type: []const u8,
        child_slot: u16,
    ) void {
        if (builtin.os.tag != .linux) return;

        // Children changed is emitted on the parent
        // For simplicity, emit on root path
        var msg = dbus.Message.newSignal(
            APP_A11Y_PATH,
            ATSPI_EVENT_OBJECT_INTERFACE,
            "ChildrenChanged",
        ) catch return;
        defer msg.deinit();

        var iter = msg.iterInitAppend();

        // change_type: "add" or "remove"
        var type_z_buf: [16]u8 = undefined;
        const type_z = std.fmt.bufPrintZ(&type_z_buf, "{s}", .{change_type}) catch return;
        if (!iter.appendString(type_z)) return;

        // detail1: child index
        if (!iter.appendInt32(@intCast(child_slot))) return;

        // detail2: unused
        if (!iter.appendInt32(0)) return;

        // any_data: child accessible reference (variant)
        if (!iter.appendVariantString("")) return;

        conn.send(&msg) catch return;
    }

    fn emitFocusSignal(self: *Self, conn: *Connection, path: []const u8) void {
        if (builtin.os.tag != .linux) return;

        const path_z = self.makePathZ(path) orelse return;

        // AT-SPI2 uses org.a11y.atspi.Event.Focus interface
        var msg = dbus.Message.newSignal(
            path_z,
            "org.a11y.atspi.Event.Focus",
            "Focus",
        ) catch return;
        defer msg.deinit();

        var iter = msg.iterInitAppend();

        // Empty detail string
        if (!iter.appendString("")) return;

        // detail1, detail2
        if (!iter.appendInt32(0)) return;
        if (!iter.appendInt32(0)) return;

        // any_data variant
        if (!iter.appendVariantString("")) return;

        conn.send(&msg) catch return;
    }

    fn emitAnnouncementSignal(self: *Self, message: []const u8, live: types.Live) void {
        if (builtin.os.tag != .linux) return;

        const conn = &(self.connection orelse return);

        // Announcement signal on root path
        var msg = dbus.Message.newSignal(
            APP_A11Y_PATH,
            ATSPI_EVENT_OBJECT_INTERFACE,
            "Announcement",
        ) catch return;
        defer msg.deinit();

        var iter = msg.iterInitAppend();

        // detail: live region priority
        const priority: []const u8 = switch (live) {
            .assertive => "assertive",
            .polite => "polite",
            .off => "off",
        };
        var priority_z_buf: [16]u8 = undefined;
        const priority_z = std.fmt.bufPrintZ(&priority_z_buf, "{s}", .{priority}) catch return;
        if (!iter.appendString(priority_z)) return;

        // detail1, detail2
        if (!iter.appendInt32(0)) return;
        if (!iter.appendInt32(0)) return;

        // Message as variant
        var msg_z_buf: [512]u8 = undefined;
        const msg_z = std.fmt.bufPrintZ(&msg_z_buf, "{s}", .{message}) catch return;
        if (!iter.appendVariantString(msg_z)) return;

        conn.send(&msg) catch return;
    }

    // =========================================================================
    // AT-SPI2 Registration
    // =========================================================================

    /// Check if AT-SPI2 is enabled and a screen reader is running
    fn checkAtSpiActive(self: *Self) bool {
        if (builtin.os.tag != .linux) return false;

        const conn = &(self.connection orelse return false);

        // Query org.a11y.Bus /org/a11y/bus GetAddress to see if AT-SPI bus is available
        // Then check org.a11y.Status.IsEnabled
        var msg = dbus.Message.newMethodCall(
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Bus",
            "GetAddress",
        ) catch return false;
        defer msg.deinit();

        const reply = conn.callMethod(&msg, DBUS_TIMEOUT_MS) catch return false;
        defer {
            var reply_mut = reply;
            reply_mut.deinit();
        }

        // If we got a reply, AT-SPI bus is available
        // For simplicity, assume if bus is available, a screen reader might be listening
        return true;
    }

    /// Register our application with the AT-SPI2 registry
    fn registerWithAtSpi(self: *Self) !void {
        if (builtin.os.tag != .linux) return;

        // Assertion: connection must exist
        std.debug.assert(self.connection != null);

        // Get the AT-SPI bus address
        // Then register our application root with the cache

        // For now, we just mark ourselves as ready to respond to queries
        // The actual registration happens when screen readers discover us
        // via the session bus
    }

    /// Unregister from AT-SPI2 registry
    fn unregisterFromAtSpi(self: *Self) void {
        if (builtin.os.tag != .linux) return;
        _ = self;
        // Send de-registration signal if needed
    }

    // =========================================================================
    // Utility
    // =========================================================================

    fn castSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }
};

// ============================================================================
// Tests
// ============================================================================

test "linux bridge initialization" {
    var bridge_inst = LinuxBridge.init();
    defer bridge_inst.bridge().deinit();

    // Bridge should be usable regardless of platform/D-Bus availability
    const b = bridge_inst.bridge();

    var tree = tree_mod.Tree.init();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test" });
    tree.popElement();
    tree.endFrame();

    // These should all be safe no-ops when AT-SPI isn't running
    b.syncDirty(&tree, tree.getDirtyElements());
    b.removeElements(tree.getRemovedFingerprints());
    b.announce("Test announcement", .polite);
    b.focusChanged(&tree, null);
}

test "linux bridge object slot management" {
    var bridge_inst = LinuxBridge.init();

    const fp1 = fingerprint_mod.compute(.button, "Button1", null, 0);
    const fp2 = fingerprint_mod.compute(.checkbox, "Check1", null, 1);

    // First allocation should succeed
    const slot1 = bridge_inst.findOrAllocSlot(fp1);
    try std.testing.expect(slot1 != null);

    // Same fingerprint should return same slot
    const slot1_again = bridge_inst.findOrAllocSlot(fp1);
    try std.testing.expectEqual(slot1, slot1_again);

    // Different fingerprint should get different slot
    const slot2 = bridge_inst.findOrAllocSlot(fp2);
    try std.testing.expect(slot2 != null);
    try std.testing.expect(slot1.? != slot2.?);

    // Find by fingerprint should work
    const found = bridge_inst.findSlotByFingerprint(fp1);
    try std.testing.expectEqual(slot1, found);
}

test "linux bridge a11y object update" {
    var obj = LinuxBridge.A11yObject{};

    // Create a mock element
    const fp = fingerprint_mod.compute(.button, "TestBtn", null, 0);
    var elem = tree_mod.Element.init(
        @import("../layout/layout.zig").LayoutId.none,
        fp,
        .button,
    );
    elem.name = "Test Button";
    elem.state.focused = true;

    // Update object
    const changes = obj.update(&elem, 42);

    // Verify updates
    try std.testing.expect(obj.active);
    try std.testing.expectEqual(types.Role.button, obj.role);
    try std.testing.expectEqualStrings("Test Button", obj.name());
    try std.testing.expect(obj.state.focused);
    try std.testing.expect(obj.path_len > 0);

    // First update should show role changed
    try std.testing.expect(changes.role_changed);
    try std.testing.expect(changes.name_changed);
    try std.testing.expect(changes.state_changed);

    // Second update with same data should show no changes
    const changes2 = obj.update(&elem, 42);
    try std.testing.expect(!changes2.role_changed);
    try std.testing.expect(!changes2.name_changed);
    try std.testing.expect(!changes2.state_changed);
}

test "linux bridge signal queue" {
    var bridge_inst = LinuxBridge.init();

    // Queue some signals
    bridge_inst.queueSignal(0, .property_change_name, .{});
    bridge_inst.queueSignal(1, .state_changed_focused, .{ .state_value = true });
    bridge_inst.queueSignal(2, .children_changed_add, .{});

    try std.testing.expectEqual(@as(u8, 3), bridge_inst.signal_count);

    // Emit clears the queue
    bridge_inst.emitPendingSignals();
    try std.testing.expectEqual(@as(u8, 0), bridge_inst.signal_count);
}
