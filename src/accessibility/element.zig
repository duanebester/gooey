const std = @import("std");
const types = @import("types.zig");
const fingerprint_mod = @import("fingerprint.zig");
const layout = @import("../layout/layout.zig");

pub const TextSelection = struct { start: u32, end: u32 };

pub const Element = struct {
    fingerprint: fingerprint_mod.Fingerprint,

    role: types.Role,

    name: ?[]const u8 = null,

    description: ?[]const u8 = null,

    value: ?[]const u8 = null,

    selection: ?TextSelection = null,

    state: types.State = .{},

    live: types.Live = .off,

    heading_level: types.HeadingLevel = .none,

    value_min: ?f32 = null,
    value_max: ?f32 = null,
    value_now: ?f32 = null,
    orientation: ?types.Orientation = null,

    pos_in_set: ?u16 = null,

    set_size: ?u16 = null,

    parent: ?u16 = null,
    first_child: ?u16 = null,
    last_child: ?u16 = null,
    next_sibling: ?u16 = null,
    child_count: u16 = 0,

    labelled_by: ?u16 = null,

    described_by: ?u16 = null,

    controls: ?u16 = null,

    bounds: layout.BoundingBox = .{},

    const Self = @This();

    pub fn isAccessible(self: *const Self) bool {
        std.debug.assert(self.fingerprint.isValid() or self.role == .presentation or self.role == .none);
        std.debug.assert(@backingInt(self.role) <= @backingInt(types.Role.none));

        return self.role != .presentation and
            self.role != .none and
            !self.state.hidden;
    }

    pub fn isFocusable(self: *const Self) bool {
        std.debug.assert(self.fingerprint.isValid() or !self.isAccessible());
        std.debug.assert(@as(u16, @bitCast(self.state)) <= 0x0FFF);

        if (self.state.disabled or self.state.hidden) return false;
        return self.role.isFocusableByDefault();
    }

    pub fn contentHash(self: *const Self) u32 {
        std.debug.assert(self.fingerprint.isValid() or self.role == .presentation);
        std.debug.assert(@as(u16, @bitCast(self.state)) <= 0x0FFF);

        var h = std.hash.Wyhash.init(0);

        h.update(std.mem.asBytes(&self.fingerprint));

        h.update(std.mem.asBytes(&self.state));

        if (self.name) |n| h.update(n);
        if (self.value) |v| h.update(v);
        if (self.description) |d| h.update(d);

        if (self.selection) |s| h.update(std.mem.asBytes(&s));

        if (self.value_now) |vn| h.update(std.mem.asBytes(&vn));
        if (self.value_min) |vm| h.update(std.mem.asBytes(&vm));
        if (self.value_max) |vx| h.update(std.mem.asBytes(&vx));
        if (self.orientation) |o| h.update(std.mem.asBytes(&o));

        if (self.pos_in_set) |p| h.update(std.mem.asBytes(&p));
        if (self.set_size) |s| h.update(std.mem.asBytes(&s));

        h.update(std.mem.asBytes(&self.heading_level));

        return @truncate(h.final());
    }

    pub fn hasChildren(self: *const Self) bool {
        std.debug.assert(self.child_count == 0 or self.first_child != null);
        std.debug.assert(self.child_count == 0 or self.last_child != null);
        return self.child_count > 0;
    }

    pub fn isContainer(self: *const Self) bool {
        std.debug.assert(@backingInt(self.role) <= @backingInt(types.Role.none));
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

    pub fn isLiveRegion(self: *const Self) bool {
        std.debug.assert(@backingInt(self.live) <= @backingInt(types.Live.assertive));
        return self.live != .off or self.role == .alert or self.role == .status;
    }

    pub fn effectiveLive(self: *const Self) types.Live {
        std.debug.assert(@backingInt(self.live) <= @backingInt(types.Live.assertive));
        if (self.live != .off) return self.live;
        return switch (self.role) {
            .alert => .assertive,
            .status => .polite,
            else => .off,
        };
    }

    pub fn init(fp: fingerprint_mod.Fingerprint, role: types.Role) Self {
        std.debug.assert(fp.isValid() or role == .presentation or role == .none);
        std.debug.assert(@backingInt(role) <= @backingInt(types.Role.none));

        return Self{
            .fingerprint = fp,
            .role = role,
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Element) <= 192);

    std.debug.assert(@alignOf(Element) <= 8);
}

test "element accessibility check" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem = Element.init(fp, .button);
    try std.testing.expect(elem.isAccessible());

    elem.role = .presentation;
    try std.testing.expect(!elem.isAccessible());

    elem.role = .button;
    elem.state.hidden = true;
    try std.testing.expect(!elem.isAccessible());
}

test "element focusability" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem = Element.init(fp, .button);
    try std.testing.expect(elem.isFocusable());

    elem.state.disabled = true;
    try std.testing.expect(!elem.isFocusable());

    elem.state.disabled = false;
    elem.role = .group;
    try std.testing.expect(!elem.isFocusable());

    elem.role = .textbox;
    try std.testing.expect(elem.isFocusable());
}

test "element content hash stability" {
    const fp = fingerprint_mod.compute(.button, "Submit", null, 0);

    const elem1 = Element{
        .fingerprint = fp,
        .role = .button,
        .name = "Submit",
        .state = .{ .focused = true },
    };

    const elem2 = Element{
        .fingerprint = fp,
        .role = .button,
        .name = "Submit",
        .state = .{ .focused = true },
    };

    try std.testing.expectEqual(elem1.contentHash(), elem2.contentHash());

    var elem3 = elem1;
    elem3.state.focused = false;
    try std.testing.expect(elem1.contentHash() != elem3.contentHash());

    var field = Element.init(fp, .textbox);
    field.value = "milk";
    var caret = field;
    caret.selection = .{ .start = 0, .end = 0 };
    try std.testing.expect(field.contentHash() != caret.contentHash());
    var selected = caret;
    selected.selection = .{ .start = 0, .end = 2 };
    try std.testing.expect(caret.contentHash() != selected.contentHash());
}

test "element content hash ignores bounds" {
    const fp = fingerprint_mod.compute(.button, "Test", null, 0);

    var elem1 = Element.init(fp, .button);
    elem1.name = "Test";
    elem1.bounds = .{ .x = 0, .y = 0, .width = 100, .height = 50 };

    var elem2 = Element.init(fp, .button);
    elem2.name = "Test";
    elem2.bounds = .{ .x = 200, .y = 300, .width = 100, .height = 50 };

    try std.testing.expectEqual(elem1.contentHash(), elem2.contentHash());
}

test "element live region detection" {
    const fp = fingerprint_mod.compute(.group, "Test", null, 0);

    var elem = Element.init(fp, .group);
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

    var elem = Element.init(fp, .button);
    try std.testing.expect(!elem.isContainer());

    elem.role = .group;
    try std.testing.expect(elem.isContainer());

    elem.role = .dialog;
    try std.testing.expect(elem.isContainer());

    elem.role = .listbox;
    try std.testing.expect(elem.isContainer());
}
