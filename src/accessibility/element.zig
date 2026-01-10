//! Accessible element - the a11y parallel to LayoutElement.
//!
//! Stored in a fixed-size pool. Contains semantic information
//! that maps to platform accessibility APIs.

const std = @import("std");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const constants = @import("constants.zig");
const layout = @import("../layout/layout.zig");

pub const Element = struct {
    // =========================================================================
    // Identity
    // =========================================================================

    /// Links to visual element (for bounds lookup)
    layout_id: layout.LayoutId,

    /// Stable identity across frames
    fingerprint: fingerprint_mod.Fingerprint,

    // =========================================================================
    // Semantics
    // =========================================================================

    /// What is this element?
    role: types.Role,

    /// Primary label (e.g., button text, input label)
    /// Slice into component's string - zero-copy within frame
    name: ?[]const u8 = null,

    /// Additional description/help text
    description: ?[]const u8 = null,

    /// Current value (e.g., slider "50%", textbox content)
    value: ?[]const u8 = null,

    /// Current state flags
    state: types.State = .{},

    /// Live region behavior
    live: types.Live = .off,

    /// Heading level (1-6, .none = not a heading)
    heading_level: types.HeadingLevel = .none,

    // =========================================================================
    // Range values (for sliders, progress bars)
    // =========================================================================

    value_min: ?f32 = null,
    value_max: ?f32 = null,
    value_now: ?f32 = null,

    // =========================================================================
    // Collection info (for lists, tabs, etc.)
    // =========================================================================

    /// 1-based position in set
    pos_in_set: ?u16 = null,

    /// Total items in set
    set_size: ?u16 = null,

    // =========================================================================
    // Tree structure (indices into element pool)
    // =========================================================================

    parent: ?u16 = null,
    first_child: ?u16 = null,
    last_child: ?u16 = null, // O(1) child append
    next_sibling: ?u16 = null,
    child_count: u16 = 0,

    // =========================================================================
    // Relationships (indices into element pool)
    // =========================================================================

    /// Element that labels this one
    labelled_by: ?u16 = null,

    /// Element that describes this one
    described_by: ?u16 = null,

    /// Element this one controls
    controls: ?u16 = null,

    // =========================================================================
    // Bounds (copied from layout for platform queries)
    // =========================================================================

    bounds: layout.BoundingBox = .{},

    // =========================================================================
    // Methods
    // =========================================================================

    const Self = @This();

    /// Check if element should be exposed to assistive technology
    pub fn isAccessible(self: *const Self) bool {
        // Assertion: fingerprint must be valid for accessible elements
        std.debug.assert(self.fingerprint.isValid() or self.role == .presentation or self.role == .none);
        // Assertion: role is within valid enum range
        std.debug.assert(@intFromEnum(self.role) <= @intFromEnum(types.Role.none));

        return self.role != .presentation and
            self.role != .none and
            !self.state.hidden;
    }

    /// Check if element accepts keyboard focus
    pub fn isFocusable(self: *const Self) bool {
        // Assertion: can't check focusability of hidden elements meaningfully
        std.debug.assert(self.fingerprint.isValid() or !self.isAccessible());
        // Assertion: disabled state should be explicitly set, not garbage
        std.debug.assert(@as(u16, @bitCast(self.state)) <= 0x0FFF); // Only 12 bits used

        if (self.state.disabled or self.state.hidden) return false;
        return self.role.isFocusableByDefault();
    }

    /// Compute content hash for dirty detection.
    /// Excludes bounds (position changes don't need re-announcement).
    pub fn contentHash(self: *const Self) u32 {
        // Assertion: fingerprint must be initialized before hashing
        std.debug.assert(self.fingerprint.isValid() or self.role == .presentation);
        // Assertion: state bits are valid (12 bools in bits 0-11, reserved u4 in bits 12-15 must be 0)
        std.debug.assert(@as(u16, @bitCast(self.state)) <= 0x0FFF);

        var h = std.hash.Wyhash.init(0);

        // Hash identity
        h.update(std.mem.asBytes(&self.fingerprint));

        // Hash state
        h.update(std.mem.asBytes(&self.state));

        // Hash text content
        if (self.name) |n| h.update(n);
        if (self.value) |v| h.update(v);
        if (self.description) |d| h.update(d);

        // Hash numeric values
        if (self.value_now) |vn| h.update(std.mem.asBytes(&vn));
        if (self.value_min) |vm| h.update(std.mem.asBytes(&vm));
        if (self.value_max) |vx| h.update(std.mem.asBytes(&vx));

        // Hash collection info
        if (self.pos_in_set) |p| h.update(std.mem.asBytes(&p));
        if (self.set_size) |s| h.update(std.mem.asBytes(&s));

        // Hash heading level
        h.update(std.mem.asBytes(&self.heading_level));

        return @truncate(h.final());
    }

    /// Check if this element has any children
    pub fn hasChildren(self: *const Self) bool {
        std.debug.assert(self.child_count == 0 or self.first_child != null);
        std.debug.assert(self.child_count == 0 or self.last_child != null);
        return self.child_count > 0;
    }

    /// Check if this element is a container (group, region, dialog, etc.)
    pub fn isContainer(self: *const Self) bool {
        std.debug.assert(@intFromEnum(self.role) <= @intFromEnum(types.Role.none));
        return switch (self.role) {
            .group,
            .region,
            .dialog,
            .alertdialog,
            .toolbar,
            .menu,
            .menubar,
            .listbox,
            .tree,
            .tablist,
            .tabpanel,
            .list,
            => true,
            else => false,
        };
    }

    /// Check if this element is a live region
    pub fn isLiveRegion(self: *const Self) bool {
        std.debug.assert(@intFromEnum(self.live) <= @intFromEnum(types.Live.assertive));
        return self.live != .off or self.role == .alert or self.role == .status;
    }

    /// Get effective live politeness (accounts for role-based defaults)
    pub fn effectiveLive(self: *const Self) types.Live {
        std.debug.assert(@intFromEnum(self.live) <= @intFromEnum(types.Live.assertive));
        if (self.live != .off) return self.live;
        return switch (self.role) {
            .alert => .assertive,
            .status => .polite,
            else => .off,
        };
    }

    /// Create element with minimal required fields
    pub fn init(
        layout_id: layout.LayoutId,
        fp: fingerprint_mod.Fingerprint,
        role: types.Role,
    ) Self {
        std.debug.assert(fp.isValid() or role == .presentation or role == .none);
        std.debug.assert(@intFromEnum(role) <= @intFromEnum(types.Role.none));

        return Self{
            .layout_id = layout_id,
            .fingerprint = fp,
            .role = role,
        };
    }
};

// Compile-time size check per CLAUDE.md
comptime {
    // Element should fit in ~160 bytes for cache efficiency
    // Actual size depends on slice representation and alignment
    std.debug.assert(@sizeOf(Element) <= 192);

    // Alignment should be reasonable
    std.debug.assert(@alignOf(Element) <= 8);
}

test "element accessibility check" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem = Element.init(layout.LayoutId.none, fp, .button);
    try std.testing.expect(elem.isAccessible());

    // Presentation role is not accessible
    elem.role = .presentation;
    try std.testing.expect(!elem.isAccessible());

    // Hidden state makes element inaccessible
    elem.role = .button;
    elem.state.hidden = true;
    try std.testing.expect(!elem.isAccessible());
}

test "element focusability" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem = Element.init(layout.LayoutId.none, fp, .button);
    try std.testing.expect(elem.isFocusable());

    // Disabled elements are not focusable
    elem.state.disabled = true;
    try std.testing.expect(!elem.isFocusable());

    // Groups are not focusable by default
    elem.state.disabled = false;
    elem.role = .group;
    try std.testing.expect(!elem.isFocusable());

    // Text inputs are focusable
    elem.role = .textbox;
    try std.testing.expect(elem.isFocusable());
}

test "element content hash stability" {
    const fp = fingerprint_mod.compute(.button, "Submit", null, 0);

    const elem1 = Element{
        .layout_id = layout.LayoutId.none,
        .fingerprint = fp,
        .role = .button,
        .name = "Submit",
        .state = .{ .focused = true },
    };

    const elem2 = Element{
        .layout_id = layout.LayoutId.none,
        .fingerprint = fp,
        .role = .button,
        .name = "Submit",
        .state = .{ .focused = true },
    };

    // Same content should produce same hash
    try std.testing.expectEqual(elem1.contentHash(), elem2.contentHash());

    // Different state should produce different hash
    var elem3 = elem1;
    elem3.state.focused = false;
    try std.testing.expect(elem1.contentHash() != elem3.contentHash());
}

test "element content hash ignores bounds" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem1 = Element.init(layout.LayoutId.none, fp, .button);
    elem1.name = "Test";
    elem1.bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 };

    var elem2 = Element.init(layout.LayoutId.none, fp, .button);
    elem2.name = "Test";
    elem2.bounds = .{ .x = 200, .y = 300, .width = 100, .height = 50 };

    // Bounds changes should not affect content hash
    try std.testing.expectEqual(elem1.contentHash(), elem2.contentHash());
}

test "element live region detection" {
    const fp = fingerprint_mod.compute(.group, "Test", null, 0);

    var elem = Element.init(layout.LayoutId.none, fp, .group);
    try std.testing.expect(!elem.isLiveRegion());

    elem.live = .polite;
    try std.testing.expect(elem.isLiveRegion());

    elem.live = .off;
    elem.role = .alert;
    try std.testing.expect(elem.isLiveRegion());
    try std.testing.expectEqual(types.Live.assertive, elem.effectiveLive());

    elem.role = .status;
    try std.testing.expectEqual(types.Live.polite, elem.effectiveLive());
}

test "element container check" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem = Element.init(layout.LayoutId.none, fp, .button);
    try std.testing.expect(!elem.isContainer());

    elem.role = .group;
    try std.testing.expect(elem.isContainer());

    elem.role = .dialog;
    try std.testing.expect(elem.isContainer());

    elem.role = .listbox;
    try std.testing.expect(elem.isContainer());
}
