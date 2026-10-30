//! The Windows bridge's own copy of the accessibility tree.
//!
//! UI Automation is pull-based: clients query providers between frames, after
//! the frame that built `Tree` has ended and the strings it borrowed may be
//! gone. So each synced frame copies everything a provider can be asked about
//! (structure, roles, states, bounds, and text) into storage the bridge owns,
//! and providers read only this snapshot. The snapshot is pure data with no
//! Win32 calls, so it is tested directly.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Entries: `MAX_ELEMENTS` (2,048) of 96 B, 192 KiB, reserved at init.
//! - Text: at most `text_bytes_element_max` (1 KiB) per element, 2 MiB
//!   reserved at init. Pages become resident only where a frame writes, so a
//!   typical UI touches a few KiB.
//! - Per synced frame: one pass over at most 2,048 elements, at most 2 MiB of
//!   text copied, and one insert each into a 4,096-bucket map. No allocation.
//! - Text longer than its cap is truncated at a UTF-8 boundary. That is the
//!   overload behaviour: a screen reader reads the first 256 bytes of a name.

const std = @import("std");
const constants = @import("constants.zig");
const types = @import("types.zig");
const tree_mod = @import("tree.zig");
const reservation = @import("../core/reservation.zig");
const layout = @import("../layout/layout.zig");

const assert = std.debug.assert;
const Element = tree_mod.Element;
const Fingerprint = tree_mod.Fingerprint;
const Tree = tree_mod.Tree;

/// Sentinel for an absent parent, child, sibling, or focus index.
pub const index_none: u16 = 0xFFFF;

pub const name_bytes_max: u16 = 256;
pub const value_bytes_max: u16 = 512;
pub const description_bytes_max: u16 = 256;
pub const text_bytes_element_max: u32 = name_bytes_max + value_bytes_max + description_bytes_max;
pub const text_bytes_max: u32 = @as(u32, constants.MAX_ELEMENTS) * text_bytes_element_max;

/// Property changes recorded per frame before the queue reports overflow.
pub const change_count_max: u16 = 128;

/// A string in the snapshot's text storage.
pub const Text = struct {
    offset: u32,
    len: u16,
};

pub const Entry = struct {
    fingerprint: Fingerprint,
    /// Logical pixels, relative to the window's client area.
    bounds: layout.BoundingBox,
    value_now: f32,
    value_min: f32,
    value_max: f32,
    name: Text,
    value: Text,
    description: Text,
    /// Hashes of the full source strings, compared to detect changes.
    name_hash: u32,
    value_hash: u32,
    description_hash: u32,
    parent: u16,
    first_child: u16,
    last_child: u16,
    previous_sibling: u16,
    next_sibling: u16,
    /// One-based; zero when the element is not in a set.
    pos_in_set: u16,
    /// Zero when the element is not in a set.
    set_size: u16,
    state: types.State,
    role: types.Role,
    heading_level: types.HeadingLevel,
    live: types.Live,
    has_value_now: bool,

    /// Whether an assistive technology should see this element as a control.
    pub fn isExposed(self: *const Entry) bool {
        assert(self.fingerprint.isValid());
        assert(self.parent == index_none or self.parent < constants.MAX_ELEMENTS);
        if (self.state.hidden) return false;
        return self.role != .presentation and self.role != .none;
    }

    pub fn isFocusable(self: *const Entry) bool {
        assert(@as(u16, @bitCast(self.state)) <= 0x0FFF);
        if (self.state.disabled or self.state.hidden) return false;
        return self.role.isFocusableByDefault();
    }
};

/// A property whose change the bridge raises as a UI Automation event.
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

/// One frame's changes. Overflow is reported, not hidden: the bridge answers
/// it by invalidating the whole tree, so clients re-read every property.
pub const ChangeList = struct {
    changes: [change_count_max]Change = undefined,
    change_count: u16 = 0,
    /// An element appeared that the previous snapshot did not have.
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

    /// Reserve the entry and text storage. Nothing is written beyond the
    /// scalars and the map's buckets, so the reservations stay non-resident.
    pub fn initInPlace(self: *Self) error{OutOfMemory}!void {
        self.entries = try reservation.reserve(Entry, constants.MAX_ELEMENTS);
        errdefer reservation.release(Entry, self.entries, 0);

        self.text = try reservation.reserve(u8, text_bytes_max);
        errdefer reservation.release(u8, self.text, 0);

        self.map.clear();
        self.entry_count = 0;
        self.entry_count_high_water = 0;
        self.text_used = 0;
        self.text_used_high_water = 0;
        self.root_first_child = index_none;
        self.root_last_child = index_none;
        self.focused = index_none;
        assert(self.entries.len == constants.MAX_ELEMENTS);
        assert(self.text.len == text_bytes_max);
    }

    /// Zero what any frame wrote and return the storage (CLAUDE.md §21).
    pub fn deinit(self: *Self) void {
        assert(self.entry_count <= self.entry_count_high_water);
        assert(self.text_used <= self.text_used_high_water);
        reservation.release(Entry, self.entries, self.entry_count_high_water);
        reservation.release(u8, self.text, self.text_used_high_water);
        self.entries = &.{};
        self.text = &.{};
    }

    /// Replace the snapshot with `tree`, which must be a finished frame.
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
            if (element.fingerprint.isValid()) self.map.insert(element.fingerprint, index);
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
    }

    /// Append `index` to its parent's children, or to the root's. `Tree`
    /// links only children of a parent; top-level elements are linked here so
    /// the root can navigate them too. Pre-order indices keep sibling order.
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

    /// Record what changed in `tree` relative to this snapshot, which must
    /// still hold the previous frame. Call before `rebuild`.
    pub fn collectChanges(
        self: *const Self,
        tree: *const Tree,
        dirty: []const u16,
        list: *ChangeList,
    ) void {
        assert(dirty.len <= constants.MAX_ELEMENTS);
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

    /// The last exposed element in pre-order whose bounds contain the point,
    /// in logical client pixels: the deepest element of the topmost branch.
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
    assert(previous.role == element.role); // The fingerprint includes the role.
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

/// The longest prefix of `text` that fits in `bytes_max` and ends on a UTF-8
/// code point boundary.
pub fn utf8PrefixLength(text: []const u8, comptime bytes_max: u16) u16 {
    comptime assert(bytes_max > 0);
    if (text.len <= bytes_max) return @intCast(text.len);
    var len: u16 = bytes_max;
    // A continuation byte at `len` means the cut splits a code point. A code
    // point has at most three continuation bytes.
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

// =============================================================================
// Patterns by role
// =============================================================================
//
// Support is fixed per role, and the role is part of the fingerprint, so a
// provider's interfaces never change during its lifetime as COM requires.

pub fn supportsValue(role: types.Role) bool {
    return switch (role) {
        .textbox, .textarea, .searchbox, .combobox => true,
        else => false,
    };
}

pub fn supportsRangeValue(role: types.Role) bool {
    return switch (role) {
        .slider, .progressbar, .scrollbar, .spinbutton => true,
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

/// A radio button reports selection through `checked`; everything else
/// through `selected`.
pub fn isSelected(role: types.Role, state: types.State) bool {
    assert(supportsSelectionItem(role));
    if (role == .radio) return state.checked;
    return state.selected;
}

comptime {
    assert(constants.MAX_ELEMENTS < index_none);
    assert(@sizeOf(Entry) <= 96);
    assert(text_bytes_max <= std.math.maxInt(u32));
    assert(name_bytes_max <= value_bytes_max);
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

fn createTree() !*Tree {
    const tree = try testing.allocator.create(Tree);
    tree.initInPlace();
    return tree;
}

fn createSnapshot() !*Snapshot {
    const snapshot = try testing.allocator.create(Snapshot);
    errdefer testing.allocator.destroy(snapshot);
    try snapshot.initInPlace();
    return snapshot;
}

fn destroySnapshot(snapshot: *Snapshot) void {
    snapshot.deinit();
    testing.allocator.destroy(snapshot);
}

test "rebuild links children and top-level siblings" {
    // Goal: navigation works from the snapshot alone, including between
    // top-level elements, which `Tree` itself does not link.
    const tree = try createTree();
    defer testing.allocator.destroy(tree);
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

test "text is copied, so it outlives the frame's strings" {
    const tree = try createTree();
    defer testing.allocator.destroy(tree);
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
    // Boundaries: exactly the cap, one past it in ASCII, and a two-byte code
    // point straddling the cap, which must be dropped whole.
    const exact: [name_bytes_max]u8 = @splat('a');
    try testing.expectEqual(name_bytes_max, utf8PrefixLength(&exact, name_bytes_max));

    const over: [name_bytes_max + 1]u8 = @splat('a');
    try testing.expectEqual(name_bytes_max, utf8PrefixLength(&over, name_bytes_max));

    var straddle: [name_bytes_max + 1]u8 = @splat('a');
    straddle[name_bytes_max - 1] = 0xC3; // "é" is C3 A9.
    straddle[name_bytes_max] = 0xA9;
    const len = utf8PrefixLength(&straddle, name_bytes_max);
    try testing.expectEqual(name_bytes_max - 1, len);
    try testing.expect(std.unicode.utf8ValidateSlice(straddle[0..len]));
}

test "a full tree with maximal text fits the text reservation exactly" {
    // Capacity test (CLAUDE.md §24): fill every element with text at every
    // cap, check the last element, then check the tree refuses one more.
    const tree = try createTree();
    defer testing.allocator.destroy(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    const name: [name_bytes_max + 8]u8 = @splat('n');
    const value: [value_bytes_max + 8]u8 = @splat('v');
    const description: [description_bytes_max + 8]u8 = @splat('d');
    tree.beginFrame();
    var index: u32 = 0;
    while (index < constants.MAX_ELEMENTS) : (index += 1) {
        const pushed = tree.pushElement(.{
            .role = .textbox,
            .name = &name,
            .value = &value,
            .description = &description,
        });
        try testing.expect(pushed != null);
        tree.popElement();
    }
    try testing.expectEqual(@as(?u16, null), tree.pushElement(.{ .role = .button }));
    tree.endFrame();
    snapshot.rebuild(tree);

    try testing.expectEqual(constants.MAX_ELEMENTS, snapshot.entry_count);
    try testing.expectEqual(text_bytes_max, snapshot.text_used);
    const last = snapshot.entry(constants.MAX_ELEMENTS - 1);
    try testing.expectEqual(value_bytes_max, last.value.len);
    try testing.expectEqual(last.previous_sibling, constants.MAX_ELEMENTS - 2);
}

test "collectChanges reports property, structure, and overflow changes" {
    const tree = try createTree();
    defer testing.allocator.destroy(tree);
    const snapshot = try createSnapshot();
    defer destroySnapshot(snapshot);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .checkbox, .name = "Subscribe" });
    tree.popElement();
    tree.endFrame();
    snapshot.rebuild(tree);

    // Same element, now checked and disabled; plus a new element.
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

    // One past the queue's capacity reports overflow instead of growing.
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
    defer testing.allocator.destroy(tree);
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
    // The bottom-right corner is exclusive.
    try testing.expectEqual(@as(?u16, 0), snapshot.hitTest(60, 30));
}
