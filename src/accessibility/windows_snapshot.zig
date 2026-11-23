const std = @import("std");
const types = @import("types.zig");
const tree_mod = @import("tree.zig");
const reservation = @import("../core/reservation.zig");
const limits = @import("../core/limits.zig");
const layout = @import("../layout/layout.zig");

const assert = std.debug.assert;
const Element = tree_mod.Element;
const Fingerprint = tree_mod.Fingerprint;
const Tree = tree_mod.Tree;

pub const index_none: u16 = 0xFFFF;

pub const name_bytes_max: u16 = 256;
pub const value_bytes_max: u16 = 512;
pub const description_bytes_max: u16 = 256;
pub const text_bytes_element_max: u32 = name_bytes_max + value_bytes_max + description_bytes_max;

pub const change_count_max: u16 = 128;

pub const Text = struct {
    offset: u32,
    len: u16,
};

pub const Entry = struct {
    fingerprint: Fingerprint,
    bounds: layout.BoundingBox,
    value_now: f32,
    value_min: f32,
    value_max: f32,
    name: Text,
    value: Text,
    description: Text,
    name_hash: u32,
    value_hash: u32,
    description_hash: u32,
    parent: u16,
    first_child: u16,
    last_child: u16,
    previous_sibling: u16,
    next_sibling: u16,
    pos_in_set: u16,
    set_size: u16,
    state: types.State,
    role: types.Role,
    heading_level: types.HeadingLevel,
    live: types.Live,
    has_value_now: bool,
    orientation: ?types.Orientation,

    pub fn isExposed(self: *const Entry) bool {
        assert(self.fingerprint.isValid());
        assert(self.parent == index_none or self.parent < limits.a11y_element_count_ceiling);
        if (self.state.hidden) return false;
        return self.role != .presentation and self.role != .none;
    }

    pub fn isFocusable(self: *const Entry) bool {
        assert(@as(u16, @bitCast(self.state)) <= 0x0FFF);
        if (self.state.disabled or self.state.hidden) return false;
        return self.role.isFocusableByDefault();
    }
};

pub const Property = enum(u8) {
    name,
    help_text,
    value,
    range_value,
    toggle_state,
    expand_collapse_state,
    is_selected,
    is_enabled,
};

pub const Change = struct {
    fingerprint: Fingerprint,
    property: Property,
};

pub const ChangeList = struct {
    changes: [change_count_max]Change = undefined,
    change_count: u16 = 0,
    structure_changed: bool = false,
    overflowed: bool = false,

    pub fn append(self: *ChangeList, change: Change) void {
        assert(change.fingerprint.isValid());
        assert(self.change_count <= change_count_max);
        if (self.change_count < change_count_max) {
            self.changes[self.change_count] = change;
            self.change_count += 1;
        } else {
            self.overflowed = true;
        }
    }

    pub fn items(self: *const ChangeList) []const Change {
        assert(self.change_count <= change_count_max);
        return self.changes[0..self.change_count];
    }
};

pub const Snapshot = struct {
    entries: []Entry,
    text: []u8,
    map: tree_mod.FingerprintMap,
    entry_count: u16,
    entry_count_high_water: u16,
    text_used: u32,
    text_used_high_water: u32,
    root_first_child: u16,
    root_last_child: u16,
    focused: u16,

    const Self = @This();

    pub fn initInPlace(self: *Self, element_count_max: u16) error{OutOfMemory}!void {
        assert(element_count_max > 0);
        self.entries = try reservation.reserve(Entry, element_count_max);
        errdefer reservation.release(Entry, self.entries, 0);

        const text_bytes = @as(u32, element_count_max) * text_bytes_element_max;
        self.text = try reservation.reserve(u8, text_bytes);
        errdefer reservation.release(u8, self.text, 0);

        const bucket_count = std.math.ceilPowerOfTwoAssert(u32, 2 * @as(u32, element_count_max));
        self.map = try tree_mod.FingerprintMap.init(bucket_count);
        self.entry_count = 0;
        self.entry_count_high_water = 0;
        self.text_used = 0;
        self.text_used_high_water = 0;
        self.root_first_child = index_none;
        self.root_last_child = index_none;
        self.focused = index_none;
        assert(self.entries.len == element_count_max);
        assert(self.text.len == text_bytes);
    }

    pub fn deinit(self: *Self) void {
        assert(self.entry_count <= self.entry_count_high_water);
        assert(self.text_used <= self.text_used_high_water);
        reservation.release(Entry, self.entries, self.entry_count_high_water);
        reservation.release(u8, self.text, self.text_used_high_water);
        self.map.deinit(true);
        self.entries = &.{};
        self.text = &.{};
    }

    pub fn rebuild(self: *Self, tree: *const Tree) void {
        const count = tree.count();
        assert(count <= self.entries.len);
        assert(tree.stack_depth == 0);

        self.map.clear();
        self.text_used = 0;
        self.root_first_child = index_none;
        self.root_last_child = index_none;
        var index: u16 = 0;
        while (index < count) : (index += 1) {
            const element = tree.getElement(index).?;
            self.writeEntry(index, element);
            self.link(index);
            if (element.fingerprint.isValid()) {
                assert(self.map.find(element.fingerprint) == null);
                self.map.insert(element.fingerprint, index);
            }
        }
        self.entry_count = count;
        self.entry_count_high_water = @max(self.entry_count_high_water, count);
        self.text_used_high_water = @max(self.text_used_high_water, self.text_used);
        self.focused = tree.getFocusedIndex() orelse index_none;

        assert(self.text_used <= @as(u32, count) * text_bytes_element_max);
        assert(self.focused == index_none or self.focused < count);
    }

    fn writeEntry(self: *Self, index: u16, element: *const Element) void {
        assert(index < self.entries.len);
        assert(element.parent == null or element.parent.? < index);
        const target = &self.entries[index];
        target.fingerprint = element.fingerprint;
        target.bounds = element.bounds;
        target.value_now = element.value_now orelse 0;
        target.value_min = element.value_min orelse 0;
        target.value_max = element.value_max orelse 100;
        target.has_value_now = element.value_now != null;
        target.name = self.copyText(element.name, name_bytes_max);
        target.value = self.copyText(element.value, value_bytes_max);
        target.description = self.copyText(element.description, description_bytes_max);
        target.name_hash = textHash(element.name);
        target.value_hash = textHash(element.value);
        target.description_hash = textHash(element.description);
        target.parent = element.parent orelse index_none;
        target.first_child = index_none;
        target.last_child = index_none;
        target.previous_sibling = index_none;
        target.next_sibling = index_none;
        target.pos_in_set = element.pos_in_set orelse 0;
        target.set_size = element.set_size orelse 0;
        target.state = element.state;
        target.role = element.role;
        target.heading_level = element.heading_level;
        target.live = element.live;
        target.orientation = element.orientation;
    }

    fn link(self: *Self, index: u16) void {
        const linked = &self.entries[index];
        const parent = linked.parent;
        assert(parent == index_none or parent < index);
        const first: *u16, const last: *u16 = if (parent == index_none)
            .{ &self.root_first_child, &self.root_last_child }
        else
            .{ &self.entries[parent].first_child, &self.entries[parent].last_child };
        if (last.* == index_none) {
            first.* = index;
        } else {
            assert(last.* < index);
            self.entries[last.*].next_sibling = index;
            linked.previous_sibling = last.*;
        }
        last.* = index;
    }

    fn copyText(self: *Self, source: ?[]const u8, comptime bytes_max: u16) Text {
        const text = source orelse return .{ .offset = self.text_used, .len = 0 };
        const len = utf8PrefixLength(text, bytes_max);
        assert(len <= bytes_max);
        assert(len <= self.text.len - self.text_used);
        @memcpy(self.text[self.text_used..][0..len], text[0..len]);
        const copied: Text = .{ .offset = self.text_used, .len = len };
        self.text_used += len;
        return copied;
    }

    pub fn collectChanges(
        self: *const Self,
        tree: *const Tree,
        dirty: []const u16,
        list: *ChangeList,
    ) void {
        assert(dirty.len <= tree.count());
        assert(list.change_count == 0);
        for (dirty) |index| {
            assert(index < tree.count());
            const element = tree.getElement(index).?;
            const previous = self.find(element.fingerprint) orelse {
                list.structure_changed = true;
                continue;
            };
            collectElementChanges(self.entry(previous), element, list);
        }
    }

    pub fn find(self: *const Self, fingerprint: Fingerprint) ?u16 {
        assert(self.entry_count <= self.entries.len);
        if (!fingerprint.isValid()) return null;
        const index = self.map.find(fingerprint) orelse return null;
        assert(index < self.entry_count);
        return index;
    }

    pub fn entry(self: *const Self, index: u16) *const Entry {
        assert(index < self.entry_count);
        assert(self.entry_count <= self.entries.len);
        return &self.entries[index];
    }

    pub fn textOf(self: *const Self, text: Text) []const u8 {
        assert(text.offset <= self.text_used);
        assert(text.len <= self.text_used - text.offset);
        return self.text[text.offset..][0..text.len];
    }

    pub fn hitTest(self: *const Self, x: f32, y: f32) ?u16 {
        assert(!std.math.isNan(x));
        assert(!std.math.isNan(y));
        var hit: ?u16 = null;
        var index: u16 = 0;
        while (index < self.entry_count) : (index += 1) {
            const candidate = &self.entries[index];
            if (!candidate.isExposed()) continue;
            if (candidate.bounds.width <= 0 or candidate.bounds.height <= 0) continue;
            if (candidate.bounds.contains(x, y)) hit = index;
        }
        return hit;
    }
};

fn collectElementChanges(previous: *const Entry, element: *const Element, list: *ChangeList) void {
    assert(previous.fingerprint.eql(element.fingerprint));
    assert(previous.role == element.role);
    const fingerprint = element.fingerprint;
    const role = element.role;
    if (previous.name_hash != textHash(element.name)) {
        list.append(.{ .fingerprint = fingerprint, .property = .name });
    }
    if (previous.description_hash != textHash(element.description)) {
        list.append(.{ .fingerprint = fingerprint, .property = .help_text });
    }
    if (supportsValue(role) and previous.value_hash != textHash(element.value)) {
        list.append(.{ .fingerprint = fingerprint, .property = .value });
    }
    if (supportsRangeValue(role) and previous.value_now != (element.value_now orelse 0)) {
        list.append(.{ .fingerprint = fingerprint, .property = .range_value });
    }
    if (supportsToggle(role) and previous.state.checked != element.state.checked) {
        list.append(.{ .fingerprint = fingerprint, .property = .toggle_state });
    }
    if (supportsExpandCollapse(role) and previous.state.expanded != element.state.expanded) {
        list.append(.{ .fingerprint = fingerprint, .property = .expand_collapse_state });
    }
    if (supportsSelectionItem(role)) {
        if (isSelected(role, previous.state) != isSelected(role, element.state)) {
            list.append(.{ .fingerprint = fingerprint, .property = .is_selected });
        }
    }
    if (previous.state.disabled != element.state.disabled) {
        list.append(.{ .fingerprint = fingerprint, .property = .is_enabled });
    }
}

pub fn utf8PrefixLength(text: []const u8, comptime bytes_max: u16) u16 {
    comptime assert(bytes_max > 0);
    if (text.len <= bytes_max) return @intCast(text.len);
    var len: u16 = bytes_max;
    var step: u8 = 0;
    while (step < 3 and len > 0 and text[len] & 0xC0 == 0x80) : (step += 1) {
        len -= 1;
    }
    assert(len <= bytes_max);
    return len;
}

fn textHash(text: ?[]const u8) u32 {
    const bytes = text orelse return 0;
    assert(bytes.len <= std.math.maxInt(u32));
    return @truncate(std.hash.Wyhash.hash(0, bytes));
}

pub fn supportsValue(role: types.Role) bool {
    return switch (role) {
        .textbox, .textarea, .searchbox, .combobox => true,
        else => false,
    };
}

pub fn supportsRangeValue(role: types.Role) bool {
    return switch (role) {
        .slider, .progressbar, .scrollbar, .spinbutton, .separator => true,
        else => false,
    };
}

pub fn supportsToggle(role: types.Role) bool {
    return switch (role) {
        .checkbox, .switch_ => true,
        else => false,
    };
}

pub fn supportsExpandCollapse(role: types.Role) bool {
    return switch (role) {
        .combobox, .treeitem, .menuitem => true,
        else => false,
    };
}

pub fn supportsSelectionItem(role: types.Role) bool {
    return switch (role) {
        .option, .tab, .treeitem, .radio => true,
        else => false,
    };
}

pub fn isSelected(role: types.Role, state: types.State) bool {
    assert(supportsSelectionItem(role));
    if (role == .radio) return state.checked;
    return state.selected;
}

comptime {
    assert(limits.a11y_element_count_ceiling < index_none);
    assert(@sizeOf(Entry) <= 96);
    assert(limits.a11y_element_count_ceiling * text_bytes_element_max <= std.math.maxInt(u32));
    assert(name_bytes_max <= value_bytes_max);
}

const testing = std.testing;

const test_capacity = tree_mod.Capacity.standard;

fn createTree() !*Tree {
    const tree = try testing.allocator.create(Tree);
    errdefer destroyTree(tree);
    try tree.initInPlace(&test_capacity);
    return tree;
}

fn destroyTree(tree: *Tree) void {
    tree.deinit();
    testing.allocator.destroy(tree);
}

fn createSnapshot() !*Snapshot {
    const snapshot = try testing.allocator.create(Snapshot);
    errdefer testing.allocator.destroy(snapshot);
    try snapshot.initInPlace(test_capacity.element_count_max);
    return snapshot;
}

fn destroySnapshot(snapshot: *Snapshot) void {
    snapshot.deinit();
    testing.allocator.destroy(snapshot);
}

test "rebuild links children and top-level siblings" {
    const tree = try createTree();
    defer destroyTree(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .group, .name = "Form" });
    _ = tree.pushElement(.{ .role = .textbox, .name = "Email" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Send", .state = .{ .focused = true } });
    tree.popElement();
    tree.popElement();
    _ = tree.pushElement(.{ .role = .status, .name = "Ready" });
    tree.popElement();
    tree.endFrame();
    snapshot.rebuild(tree);

    try testing.expectEqual(@as(u16, 4), snapshot.entry_count);
    try testing.expectEqual(@as(u16, 0), snapshot.root_first_child);
    try testing.expectEqual(@as(u16, 3), snapshot.root_last_child);
    try testing.expectEqual(@as(u16, 3), snapshot.entry(0).next_sibling);
    try testing.expectEqual(@as(u16, 0), snapshot.entry(3).previous_sibling);
    try testing.expectEqual(@as(u16, 1), snapshot.entry(0).first_child);
    try testing.expectEqual(@as(u16, 2), snapshot.entry(0).last_child);
    try testing.expectEqual(@as(u16, 2), snapshot.entry(1).next_sibling);
    try testing.expectEqual(index_none, snapshot.entry(2).next_sibling);
    try testing.expectEqual(@as(u16, 0), snapshot.entry(2).parent);
    try testing.expectEqual(@as(u16, 2), snapshot.focused);
    try testing.expectEqualStrings("Send", snapshot.textOf(snapshot.entry(2).name));
}

test "same-role, same-name top-level siblings stay distinct and navigation ends" {
    const tree = try createTree();
    defer destroyTree(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Delete" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Delete" });
    tree.popElement();
    tree.endFrame();
    snapshot.rebuild(tree);

    const first = snapshot.entry(0).fingerprint;
    const second = snapshot.entry(1).fingerprint;
    try testing.expect(!first.eql(second));
    try testing.expectEqual(@as(?u16, 0), snapshot.find(first));
    try testing.expectEqual(@as(?u16, 1), snapshot.find(second));

    var visited: u16 = 0;
    var current = snapshot.root_first_child;
    while (current != index_none) : (visited += 1) {
        try testing.expect(visited < snapshot.entry_count);
        const resolved = snapshot.find(snapshot.entry(current).fingerprint).?;
        try testing.expectEqual(current, resolved);
        current = snapshot.entry(resolved).next_sibling;
    }
    try testing.expectEqual(@as(u16, 2), visited);
}

test "text is copied, so it outlives the frame's strings" {
    const tree = try createTree();
    defer destroyTree(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    var name_buffer = "Save draft".*;
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = &name_buffer });
    tree.popElement();
    tree.endFrame();
    snapshot.rebuild(tree);

    @memset(&name_buffer, 'x');
    try testing.expectEqualStrings("Save draft", snapshot.textOf(snapshot.entry(0).name));
}

test "text is truncated at its cap on a code point boundary" {
    const exact: [name_bytes_max]u8 = @splat('a');
    try testing.expectEqual(name_bytes_max, utf8PrefixLength(&exact, name_bytes_max));

    const over: [name_bytes_max + 1]u8 = @splat('a');
    try testing.expectEqual(name_bytes_max, utf8PrefixLength(&over, name_bytes_max));

    var straddle: [name_bytes_max + 1]u8 = @splat('a');
    straddle[name_bytes_max - 1] = 0xC3;
    straddle[name_bytes_max] = 0xA9;
    const len = utf8PrefixLength(&straddle, name_bytes_max);
    try testing.expectEqual(name_bytes_max - 1, len);
    try testing.expect(std.unicode.utf8ValidateSlice(straddle[0..len]));
}

test "a full tree with maximal text fits the text reservation exactly" {
    const tree = try createTree();
    defer destroyTree(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    const name: [name_bytes_max + 8]u8 = @splat('n');
    const value: [value_bytes_max + 8]u8 = @splat('v');
    const description: [description_bytes_max + 8]u8 = @splat('d');
    tree.beginFrame();
    var index: u32 = 0;
    const element_count = test_capacity.element_count_max;
    while (index < element_count) : (index += 1) {
        _ = tree.pushElement(.{
            .role = .textbox,
            .name = &name,
            .value = &value,
            .description = &description,
        });
        tree.popElement();
    }
    try testing.expectEqual(element_count, tree.count());
    tree.endFrame();
    snapshot.rebuild(tree);

    try testing.expectEqual(element_count, snapshot.entry_count);
    try testing.expectEqual(snapshot.text.len, snapshot.text_used);
    const last = snapshot.entry(element_count - 1);
    try testing.expectEqual(value_bytes_max, last.value.len);
    try testing.expectEqual(last.previous_sibling, element_count - 2);
}

test "collectChanges reports property, structure, and overflow changes" {
    const tree = try createTree();
    defer destroyTree(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .checkbox, .name = "Subscribe" });
    tree.popElement();
    tree.endFrame();
    snapshot.rebuild(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .checkbox,
        .name = "Subscribe",
        .state = .{ .checked = true, .disabled = true },
    });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Next" });
    tree.popElement();
    tree.endFrame();

    var list: ChangeList = .{};
    snapshot.collectChanges(tree, tree.getDirtyElements(), &list);
    try testing.expect(list.structure_changed);
    try testing.expect(!list.overflowed);
    try testing.expectEqual(@as(u16, 2), list.change_count);
    try testing.expectEqual(Property.toggle_state, list.items()[0].property);
    try testing.expectEqual(Property.is_enabled, list.items()[1].property);

    var full: ChangeList = .{};
    const change: Change = .{ .fingerprint = list.items()[0].fingerprint, .property = .name };
    var count: u16 = 0;
    while (count < change_count_max) : (count += 1) full.append(change);
    try testing.expect(!full.overflowed);
    full.append(change);
    try testing.expect(full.overflowed);
    try testing.expectEqual(change_count_max, full.change_count);
}

test "hitTest finds the deepest exposed element under the point" {
    const tree = try createTree();
    defer destroyTree(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .group, .name = "Card" });
    _ = tree.pushElement(.{ .role = .button, .name = "Open" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Ghost", .state = .{ .hidden = true } });
    tree.popElement();
    tree.popElement();
    tree.endFrame();
    tree.getElementMut(0).?.bounds = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    tree.getElementMut(1).?.bounds = .{ .x = 10, .y = 10, .width = 50, .height = 20 };
    tree.getElementMut(2).?.bounds = .{ .x = 0, .y = 0, .width = 200, .height = 100 };
    snapshot.rebuild(tree);

    try testing.expectEqual(@as(?u16, 1), snapshot.hitTest(20, 15));
    try testing.expectEqual(@as(?u16, 0), snapshot.hitTest(150, 80));
    try testing.expectEqual(@as(?u16, null), snapshot.hitTest(250, 80));
    try testing.expectEqual(@as(?u16, 0), snapshot.hitTest(60, 30));
}
