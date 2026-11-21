//! Accessibility tree, rebuilt each frame and synced to the platform.
//!
//! Every capacity derives from the app's budget (`Capacity.fromLimits`), so
//! nothing is dropped: the frame that feeds the tree holds at most
//! `a11y.element_count_max` nodes nested at most `build.box_depth_max` deep,
//! and its announcements are bounded by the live-region rules of
//! `records.Announcements` before they reach the tree. Storage is reserved at
//! init from fresh pages (`core/reservation.zig`), so it stays non-resident
//! until a screen reader turns the tree on: at `standard` (2,048 elements)
//! about 0.48 MiB of virtual memory per window.

const std = @import("std");
const element_mod = @import("element.zig");
const fingerprint_mod = @import("fingerprint.zig");
const types = @import("types.zig");
const limits_mod = @import("../core/limits.zig");
const reservation = @import("../core/reservation.zig");

const assert = std.debug.assert;

pub const Element = element_mod.Element;
pub const Fingerprint = fingerprint_mod.Fingerprint;

/// Odd (golden-ratio) multiplier that spreads a duplicate fingerprint's
/// retry count across its name hash; see `Tree.uniqueFingerprint`.
const fingerprint_salt_multiplier: u32 = 0x9E3779B1;
comptime {
    assert(fingerprint_salt_multiplier % 2 == 1);
}

pub const Capacity = struct {
    /// `a11y.element_count_max`: the frame's accessibility nodes.
    element_count_max: u16,
    /// `build.box_depth_max`: a node's depth is its box nesting at most.
    depth_max: u8,
    /// The frame's pending announcements (`a11y.announcement_polite_pending_max`
    /// polite and one assertive) plus one per element: a live region whose
    /// content changed announces itself once per frame.
    announcement_count_max: u16,

    pub fn fromLimits(limits: *const limits_mod.ResourceLimits) Capacity {
        assert(limits.check() == null);
        const element_count = limits.a11y.element_count_max;
        const capacity: Capacity = .{
            .element_count_max = @intCast(element_count),
            .depth_max = @intCast(limits.build.box_depth_max),
            .announcement_count_max = @intCast(
                limits.a11y.announcement_polite_pending_max + 1 + element_count,
            ),
        };
        capacity.assertValid();
        return capacity;
    }

    /// The tests' capacity, an app's at `standard`.
    pub const standard = fromLimits(&limits_mod.ResourceLimits.standard);

    /// Twice the elements, a power of two, so linear probing stays short and
    /// the modulo is a mask.
    pub fn bucketCount(self: *const Capacity) u32 {
        const count = std.math.ceilPowerOfTwoAssert(u32, 2 * @as(u32, self.element_count_max));
        assert(count >= 2 * @as(u32, self.element_count_max));
        return count;
    }

    fn assertValid(self: *const Capacity) void {
        assert(self.element_count_max > 0);
        assert(self.element_count_max <= limits_mod.a11y_element_count_ceiling);
        assert(self.depth_max > 0);
        assert(self.depth_max <= limits_mod.box_depth_ceiling);
        assert(self.announcement_count_max > self.element_count_max);
    }
};

/// Open addressing with linear probing; the bucket count is a power of two
/// for a mask modulo. A bucket holds its element's index plus one, so zero is
/// empty and fresh pages are an empty map.
/// Public for the Windows bridge, whose snapshot indexes the same fingerprints.
pub const FingerprintMap = struct {
    /// Element index + 1, or `empty`.
    buckets: []u16,
    /// The fingerprint at each occupied bucket, for collision resolution.
    fingerprints: []Fingerprint,

    const empty: u16 = 0;

    const Self = @This();

    /// Reserve `bucket_count` empty buckets from fresh pages.
    pub fn init(bucket_count: u32) error{OutOfMemory}!Self {
        assert(std.math.isPowerOfTwo(bucket_count));
        assert(bucket_count <= 2 * limits_mod.a11y_element_count_ceiling);

        const buckets = try reservation.reserve(u16, bucket_count);
        errdefer reservation.release(u16, buckets, 0);

        const fingerprints = try reservation.reserve(Fingerprint, bucket_count);
        return .{ .buckets = buckets, .fingerprints = fingerprints };
    }

    /// Zero what any frame wrote before the pages go back: a map that was
    /// used was cleared and filled over its whole range.
    pub fn deinit(self: *Self, used: bool) void {
        const written = if (used) self.buckets.len else 0;
        reservation.release(Fingerprint, self.fingerprints, written);
        reservation.release(u16, self.buckets, written);
    }

    /// Insert fingerprint → index. Half the buckets at most are occupied, so
    /// a free one is always found within the bucket count.
    pub fn insert(self: *const Self, fp: Fingerprint, index: u16) void {
        assert(fp.isValid());
        assert(index < self.buckets.len / 2);

        const buckets = self.buckets;
        const fingerprints = self.fingerprints;
        const mask = buckets.len - 1;
        var bucket = self.hash(fp);
        var probes: usize = 0;
        while (probes < buckets.len) : (probes += 1) {
            if (buckets[bucket] == empty) {
                buckets[bucket] = index + 1;
                fingerprints[bucket] = fp;
                return;
            }
            bucket = (bucket + 1) & mask;
        }
        unreachable; // At most half the buckets are occupied.
    }

    pub fn find(self: *const Self, fp: Fingerprint) ?u16 {
        assert(fp.isValid());

        const mask = self.buckets.len - 1;
        var bucket = self.hash(fp);
        var probes: usize = 0;
        while (probes < self.buckets.len) : (probes += 1) {
            const stored = self.buckets[bucket];
            if (stored == empty) return null;
            if (self.fingerprints[bucket].eql(fp)) return stored - 1;
            bucket = (bucket + 1) & mask;
        }
        return null;
    }

    /// Fingerprints need no clearing: they are read only where a bucket is
    /// occupied.
    pub fn clear(self: *Self) void {
        @memset(self.buckets, empty);
    }

    /// Hash fingerprint to bucket index. The fingerprint's bits are already
    /// well distributed; folding the halves mixes in the name hash.
    fn hash(self: *const Self, fp: Fingerprint) usize {
        assert(std.math.isPowerOfTwo(self.buckets.len));
        const fp_u64 = fp.toU64();
        const mixed = fp_u64 ^ (fp_u64 >> 32);
        return @intCast(mixed & (self.buckets.len - 1));
    }
};

pub const Tree = struct {
    capacity: Capacity,

    elements: []Element,
    element_count: u16 = 0,
    /// Most elements any frame held; `deinit` zeroes this prefix.
    element_count_high_water: u16 = 0,

    parent_stack: []u16,
    stack_depth: u8 = 0,

    /// One per open parent. A position never exceeds the element count, so it
    /// is always below `fingerprint.position_count_max` and never saturates.
    child_positions: []u16,
    /// Position counter for top-level elements, which have no parent on the
    /// stack. Without it every top-level element took position 0, so two
    /// top-level siblings with the same role and name shared a fingerprint.
    root_child_position: u16 = 0,

    prev_fingerprints: []Fingerprint,
    prev_count: u16 = 0,

    prev_hashes: []u32,

    prev_fingerprint_map: FingerprintMap,

    dirty_indices: []u16,
    dirty_count: u16 = 0,

    removed_fingerprints: []Fingerprint,
    removed_count: u16 = 0,

    announcements: []Announcement,
    announcement_count: u16 = 0,

    root: ?u16 = null,

    focused_fingerprint: ?Fingerprint = null,

    prev_focused_fingerprint: ?Fingerprint = null,

    current_fingerprint_map: FingerprintMap,

    /// Whether any frame was built, so `deinit` zeroes the maps it wrote.
    built: bool = false,

    const Self = @This();

    pub const Announcement = struct {
        message: []const u8,
        live: types.Live,
    };

    /// Reserve every table from `capacity`. Nothing is written: fresh pages
    /// are zero, which is an empty map, and every other table is read only
    /// below a count this sets to zero.
    pub fn initInPlace(self: *Self, capacity: *const Capacity) error{OutOfMemory}!void {
        capacity.assertValid();
        const element_count: u32 = capacity.element_count_max;

        self.elements = try reservation.reserve(Element, element_count);
        errdefer reservation.release(Element, self.elements, 0);

        self.parent_stack = try reservation.reserve(u16, capacity.depth_max);
        errdefer reservation.release(u16, self.parent_stack, 0);

        self.child_positions = try reservation.reserve(u16, capacity.depth_max);
        errdefer reservation.release(u16, self.child_positions, 0);

        try self.initCrossFrame(element_count);
        errdefer self.deinitCrossFrame();

        self.announcements = try reservation.reserve(Announcement, capacity.announcement_count_max);
        errdefer reservation.release(Announcement, self.announcements, 0);

        self.prev_fingerprint_map = try FingerprintMap.init(capacity.bucketCount());
        errdefer self.prev_fingerprint_map.deinit(false);

        self.current_fingerprint_map = try FingerprintMap.init(capacity.bucketCount());

        self.capacity = capacity.*;
        self.resetCounts();
        assert(self.elements.len == capacity.element_count_max);
        assert(self.parent_stack.len == self.child_positions.len);
    }

    fn initCrossFrame(self: *Self, element_count: u32) error{OutOfMemory}!void {
        self.prev_fingerprints = try reservation.reserve(Fingerprint, element_count);
        errdefer reservation.release(Fingerprint, self.prev_fingerprints, 0);

        self.prev_hashes = try reservation.reserve(u32, element_count);
        errdefer reservation.release(u32, self.prev_hashes, 0);

        self.dirty_indices = try reservation.reserve(u16, element_count);
        errdefer reservation.release(u16, self.dirty_indices, 0);

        self.removed_fingerprints = try reservation.reserve(Fingerprint, element_count);
    }

    fn resetCounts(self: *Self) void {
        self.element_count = 0;
        self.element_count_high_water = 0;
        self.stack_depth = 0;
        self.root_child_position = 0;
        self.prev_count = 0;
        self.dirty_count = 0;
        self.removed_count = 0;
        self.announcement_count = 0;
        self.root = null;
        self.focused_fingerprint = null;
        self.prev_focused_fingerprint = null;
        self.built = false;
    }

    /// Zero every prefix any frame wrote before the pages go back. The
    /// per-element tables are written at most to the element high-water
    /// mark; the stacks and announcements are small and zeroed whole.
    pub fn deinit(self: *Self) void {
        const used: usize = self.element_count_high_water;
        const announcements = if (self.built) self.announcements.len else 0;
        self.current_fingerprint_map.deinit(self.built);
        self.prev_fingerprint_map.deinit(self.built);
        reservation.release(Announcement, self.announcements, announcements);
        self.deinitCrossFrame();
        const stack_used = if (self.built) self.parent_stack.len else 0;
        reservation.release(u16, self.child_positions, stack_used);
        reservation.release(u16, self.parent_stack, stack_used);
        reservation.release(Element, self.elements, used);
        self.* = undefined;
    }

    fn deinitCrossFrame(self: *Self) void {
        const used: usize = self.element_count_high_water;
        reservation.release(Fingerprint, self.removed_fingerprints, used);
        reservation.release(u16, self.dirty_indices, used);
        reservation.release(u32, self.prev_hashes, used);
        reservation.release(Fingerprint, self.prev_fingerprints, used);
    }

    /// Reset for new frame. Preserves cross-frame state.
    pub fn beginFrame(self: *Self) void {
        assert(self.element_count <= self.elements.len);
        // Stack balanced from the previous frame.
        assert(self.stack_depth == 0);
        // The maps are written from here on; `deinit` zeroes them.
        self.built = true;

        self.prev_count = self.element_count;
        self.prev_focused_fingerprint = self.focused_fingerprint;

        self.prev_fingerprint_map.clear();
        snapshotFrame(
            self.elements[0..self.element_count],
            self.prev_fingerprints,
            self.prev_hashes,
            self.prev_fingerprint_map,
        );

        self.element_count = 0;
        self.stack_depth = 0;
        self.root_child_position = 0;
        self.dirty_count = 0;
        self.removed_count = 0;
        self.announcement_count = 0;
        self.root = null;
        self.focused_fingerprint = null;

        self.current_fingerprint_map.clear();
    }

    /// Copy each element's fingerprint and content hash into the previous
    /// frame's tables and index it. A hot loop over slices loaded once:
    /// writes through `self` would make the compiler reload them.
    fn snapshotFrame(
        elements: []const Element,
        prev_fingerprints: []Fingerprint,
        prev_hashes: []u32,
        prev_map: FingerprintMap,
    ) void {
        assert(elements.len <= prev_fingerprints.len);
        assert(elements.len <= prev_hashes.len);
        for (elements, 0..) |*elem, i| {
            prev_fingerprints[i] = elem.fingerprint;
            prev_hashes[i] = elem.contentHash();
            if (elem.fingerprint.isValid()) {
                prev_map.insert(elem.fingerprint, @intCast(i));
            }
        }
    }

    pub fn endFrame(self: *Self) void {
        assert(self.stack_depth == 0);
        assert(self.element_count <= self.elements.len);
        self.element_count_high_water = @max(self.element_count_high_water, self.element_count);

        self.computeDirtyElements();
        self.computeRemovedElements();
    }

    fn computeDirtyElements(self: *Self) void {
        assert(self.dirty_count == 0);
        assert(self.element_count <= self.elements.len);

        const elements = self.elements[0..self.element_count];
        const prev_hashes = self.prev_hashes;
        const prev_map = self.prev_fingerprint_map;
        for (elements, 0..) |*elem, i| {
            const current_hash = elem.contentHash();

            const prev_idx = prev_map.find(elem.fingerprint);

            if (prev_idx) |pi| {
                if (prev_hashes[pi] != current_hash) {
                    self.markDirty(@intCast(i));

                    self.autoAnnounceLiveRegion(elem);
                }
            } else {
                self.markDirty(@intCast(i));
            }
        }
    }

    fn autoAnnounceLiveRegion(self: *Self, elem: *const Element) void {
        const live_level = elem.effectiveLive();
        if (live_level == .off) return;

        const content = elem.value orelse elem.name orelse return;
        if (content.len == 0) return;

        self.announce(content, live_level);
    }

    fn computeRemovedElements(self: *Self) void {
        assert(self.removed_count == 0);
        assert(self.prev_count <= self.elements.len);

        const prev_fingerprints = self.prev_fingerprints[0..self.prev_count];
        const current_map = self.current_fingerprint_map;
        for (prev_fingerprints) |prev_fp| {
            if (!prev_fp.isValid()) continue;

            const found = current_map.find(prev_fp) != null;
            if (!found) {
                // At most one removal per previous element.
                assert(self.removed_count < self.removed_fingerprints.len);
                self.removed_fingerprints[self.removed_count] = prev_fp;
                self.removed_count += 1;
            }
        }
    }

    fn findPrevByFingerprint(self: *const Self, fp: Fingerprint) ?u16 {
        assert(fp.isValid());
        return self.prev_fingerprint_map.find(fp);
    }

    pub fn findElementByFingerprint(self: *const Self, fp: Fingerprint) ?u16 {
        assert(fp.isValid());
        return self.current_fingerprint_map.find(fp);
    }

    fn markDirty(self: *Self, index: u16) void {
        assert(index < self.element_count);
        // Each element is marked at most once a frame.
        assert(self.dirty_count < self.dirty_indices.len);
        self.dirty_indices[self.dirty_count] = index;
        self.dirty_count += 1;
    }

    /// Begin an accessible element. Call at component open. The caller holds
    /// the frame's nodes to the tree's capacity (`a11y.element_count_max`,
    /// `build.box_depth_max`), so the tree always has room.
    pub fn pushElement(self: *Self, config: ElementConfig) u16 {
        assert(self.element_count < self.elements.len);
        assert(self.stack_depth < self.parent_stack.len);

        const index = self.element_count;
        const parent_idx = self.currentParent();

        const position = self.claimChildPosition();

        const parent_fp: ?Fingerprint = if (parent_idx) |pi|
            self.elements[pi].fingerprint
        else
            null;

        const fp = self.uniqueFingerprint(fingerprint_mod.compute(
            config.role,
            config.name,
            parent_fp,
            position,
        ));

        self.elements[index] = .{
            .fingerprint = fp,
            .role = config.role,
            .name = config.name,
            .description = config.description,
            .value = config.value,
            .state = config.state,
            .live = config.live,
            .heading_level = config.heading_level,
            .value_min = config.value_min,
            .value_max = config.value_max,
            .value_now = config.value_now,
            .orientation = config.orientation,
            .pos_in_set = config.pos_in_set,
            .set_size = config.set_size,
            .parent = parent_idx,
            .labelled_by = config.labelled_by,
            .described_by = config.described_by,
            .controls = config.controls,
        };

        if (fp.isValid()) {
            self.current_fingerprint_map.insert(fp, index);
        }

        self.linkToParent(index, parent_idx);
        self.trackFocus(index, config.state.focused, fp);
        self.advanceStack(index);

        return index;
    }

    /// Claim the next position under the current parent, or at the top level
    /// when no parent is open, so siblings never share a position.
    fn claimChildPosition(self: *Self) u16 {
        assert(self.element_count < self.elements.len);
        assert(self.stack_depth <= self.parent_stack.len);

        const counter = if (self.stack_depth > 0)
            &self.child_positions[self.stack_depth - 1]
        else
            &self.root_child_position;
        const position = counter.*;
        // Every position claimed this frame belongs to a distinct element.
        assert(position <= self.element_count);
        assert(position < fingerprint_mod.position_count_max);
        counter.* = position + 1;
        return position;
    }

    /// Return `computed`, or a deterministic variant of it when an element of
    /// this frame already holds it. Siblings never collide, because their
    /// positions differ, but two subtrees whose 16-bit parent contributions
    /// coincide can still yield the same role, name, and position. Bridges
    /// key element identity on the fingerprint, so a duplicate would alias two
    /// elements: UI Automation sibling navigation would loop between them.
    /// The variant depends only on pre-order, so it is as stable across
    /// frames as the tree itself.
    fn uniqueFingerprint(self: *const Self, computed: Fingerprint) Fingerprint {
        assert(computed.isValid());
        assert(self.element_count < self.elements.len);

        // Each attempt flips the name hash by a distinct value (an odd
        // multiplier is a bijection modulo 2^32). At most `element_count`
        // fingerprints are taken and one candidate may be INVALID, so
        // `element_count + 2` attempts always find a free one.
        const attempt_count_max: u32 = @as(u32, self.element_count) + 2;
        var attempt: u32 = 0;
        while (attempt < attempt_count_max) : (attempt += 1) {
            var candidate = computed;
            candidate.name_hash ^= attempt *% fingerprint_salt_multiplier;
            if (candidate.isValid()) {
                if (self.current_fingerprint_map.find(candidate) == null) return candidate;
            }
        }
        unreachable;
    }

    fn linkToParent(self: *Self, index: u16, parent_idx: ?u16) void {
        assert(index < self.elements.len);
        assert(parent_idx == null or parent_idx.? < index);

        if (parent_idx) |pi| {
            const parent = &self.elements[pi];
            if (parent.first_child == null) {
                parent.first_child = index;
            }
            if (parent.last_child) |last| {
                self.elements[last].next_sibling = index;
            }
            parent.last_child = index;
            parent.child_count += 1;
        } else {
            self.root = index;
        }
    }

    fn trackFocus(self: *Self, index: u16, is_focused: bool, fp: Fingerprint) void {
        assert(index < self.elements.len);
        assert(fp.isValid());

        if (is_focused) {
            self.focused_fingerprint = fp;
        }
    }

    fn advanceStack(self: *Self, index: u16) void {
        assert(self.stack_depth < self.parent_stack.len);
        assert(index < self.elements.len);

        self.parent_stack[self.stack_depth] = index;
        self.child_positions[self.stack_depth] = 0;
        self.stack_depth += 1;
        self.element_count += 1;
    }

    /// End current accessible element. Call at component close.
    pub fn popElement(self: *Self) void {
        assert(self.stack_depth > 0);
        assert(self.element_count > 0);

        self.stack_depth -= 1;
    }

    fn currentParent(self: *const Self) ?u16 {
        assert(self.stack_depth <= self.parent_stack.len);

        if (self.stack_depth == 0) return null;
        return self.parent_stack[self.stack_depth - 1];
    }

    /// Queue a message for screen reader announcement. A frame carries at
    /// most `a11y.announcement_polite_pending_max + 1` announcements (one
    /// assertive), and live regions add at most one per element, so there is
    /// always room.
    pub fn announce(self: *Self, message: []const u8, live: types.Live) void {
        assert(@backingInt(live) <= @backingInt(types.Live.assertive));
        assert(self.announcement_count < self.announcements.len);

        if (live == .off) return;

        self.announcements[self.announcement_count] = .{
            .message = message,
            .live = live,
        };
        self.announcement_count += 1;
    }

    pub fn getElement(self: *const Self, index: u16) ?*const Element {
        assert(self.element_count <= self.elements.len);

        if (index >= self.element_count) return null;
        return &self.elements[index];
    }

    pub fn getElementMut(self: *Self, index: u16) ?*Element {
        assert(self.element_count <= self.elements.len);

        if (index >= self.element_count) return null;
        return &self.elements[index];
    }

    pub fn getDirtyElements(self: *const Self) []const u16 {
        assert(self.dirty_count <= self.element_count);
        return self.dirty_indices[0..self.dirty_count];
    }

    pub fn getRemovedFingerprints(self: *const Self) []const Fingerprint {
        assert(self.removed_count <= self.prev_count);
        return self.removed_fingerprints[0..self.removed_count];
    }

    pub fn getAnnouncements(self: *const Self) []const Announcement {
        assert(self.announcement_count <= self.announcements.len);
        return self.announcements[0..self.announcement_count];
    }

    pub fn count(self: *const Self) u16 {
        assert(self.element_count <= self.elements.len);
        return self.element_count;
    }

    pub fn getRoot(self: *const Self) ?u16 {
        return self.root;
    }

    pub fn focusChanged(self: *const Self) bool {
        const prev = self.prev_focused_fingerprint;
        const curr = self.focused_fingerprint;

        if (prev == null and curr == null) return false;
        if (prev == null or curr == null) return true;
        return !prev.?.eql(curr.?);
    }

    pub fn getFocusedIndex(self: *const Self) ?u16 {
        assert(self.element_count <= self.elements.len);

        const fp = self.focused_fingerprint orelse return null;
        return self.findElementByFingerprint(fp);
    }

    pub fn isEmpty(self: *const Self) bool {
        return self.element_count == 0;
    }
};

pub const ElementConfig = struct {
    role: types.Role,
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    value: ?[]const u8 = null,
    state: types.State = .{},
    live: types.Live = .off,
    heading_level: types.HeadingLevel = .none,
    value_min: ?f32 = null,
    value_max: ?f32 = null,
    value_now: ?f32 = null,
    orientation: ?types.Orientation = null,
    pos_in_set: ?u16 = null,
    set_size: ?u16 = null,

    labelled_by: ?u16 = null,

    described_by: ?u16 = null,

    controls: ?u16 = null,
};

comptime {
    // ElementConfig is passed by value on every push.
    assert(@sizeOf(ElementConfig) <= 160);
    // The largest tree's maps index buckets with `u16` element indexes + 1.
    assert(2 * limits_mod.a11y_element_count_ceiling <= std.math.maxInt(u16));
}

/// A tree at the tests' capacity, on the heap like a window's.
fn createTestTree() !*Tree {
    const tree = try std.testing.allocator.create(Tree);
    errdefer std.testing.allocator.destroy(tree);
    try tree.initInPlace(&Capacity.standard);
    return tree;
}

fn destroyTestTree(tree: *Tree) void {
    tree.deinit();
    std.testing.allocator.destroy(tree);
}

test "tree basic operations" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();

    const idx = tree.pushElement(.{
        .role = .button,
        .name = "Submit",
    });

    try std.testing.expectEqual(@as(u16, 0), idx);
    try std.testing.expectEqual(@as(u16, 1), tree.count());

    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u8, 0), tree.stack_depth);
}

test "tree parent-child relationships" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();

    const parent_idx = tree.pushElement(.{
        .role = .group,
        .name = "Container",
    });

    const child1_idx = tree.pushElement(.{
        .role = .button,
        .name = "Button 1",
    });
    tree.popElement();

    const child2_idx = tree.pushElement(.{
        .role = .button,
        .name = "Button 2",
    });
    tree.popElement();

    tree.popElement();

    tree.endFrame();

    const parent = tree.getElement(parent_idx).?;
    try std.testing.expectEqual(@as(u16, 2), parent.child_count);
    try std.testing.expectEqual(child1_idx, parent.first_child.?);
    try std.testing.expectEqual(child2_idx, parent.last_child.?);

    const child1 = tree.getElement(child1_idx).?;
    try std.testing.expectEqual(parent_idx, child1.parent.?);
    try std.testing.expectEqual(child2_idx, child1.next_sibling.?);

    const child2 = tree.getElement(child2_idx).?;
    try std.testing.expectEqual(parent_idx, child2.parent.?);
    try std.testing.expectEqual(@as(?u16, null), child2.next_sibling);
}

test "tree dirty tracking" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Cancel" });
    tree.popElement();
    tree.endFrame();

    // A name change is a new fingerprint, so it counts as new and dirty.
    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);
}

test "tree removal tracking" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 2), tree.count());

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.count());
    try std.testing.expectEqual(@as(u16, 1), tree.removed_count);
}

test "tree announcements" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();

    tree.announce("File saved", .polite);
    tree.announce("Error occurred", .assertive);

    try std.testing.expectEqual(@as(u16, 2), tree.announcement_count);

    const announcements = tree.getAnnouncements();
    try std.testing.expectEqual(@as(usize, 2), announcements.len);
    try std.testing.expectEqualStrings("File saved", announcements[0].message);
    try std.testing.expectEqual(types.Live.polite, announcements[0].live);
    try std.testing.expectEqualStrings("Error occurred", announcements[1].message);
    try std.testing.expectEqual(types.Live.assertive, announcements[1].live);

    tree.endFrame();
}

test "tree focus tracking" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(?u16, null), tree.getFocusedIndex());
    try std.testing.expect(!tree.focusChanged());

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Button",
        .state = .{ .focused = true },
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(?u16, 0), tree.getFocusedIndex());
    try std.testing.expect(tree.focusChanged());

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Button",
        .state = .{ .focused = true },
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(?u16, 0), tree.getFocusedIndex());
    try std.testing.expect(!tree.focusChanged());
}

test "tree off announcements ignored" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();

    tree.announce("This should be ignored", .off);

    try std.testing.expectEqual(@as(u16, 0), tree.announcement_count);
}

test "tree fingerprint stability across frames" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    // Capture the fingerprint in frame 1.
    tree.beginFrame();
    const idx1 = tree.pushElement(.{ .role = .button, .name = "Stable" });
    const fp1 = tree.getElement(idx1).?.fingerprint;
    tree.popElement();
    tree.endFrame();

    tree.beginFrame();
    const idx2 = tree.pushElement(.{ .role = .button, .name = "Stable" });
    const fp2 = tree.getElement(idx2).?.fingerprint;
    tree.popElement();
    tree.endFrame();

    try std.testing.expect(fp1.eql(fp2));
}

test "top-level siblings with the same role and name keep distinct, stable fingerprints" {
    // Regression: every top-level element used to take position 0, so two
    // "Delete" buttons shared one identity and bridges aliased them. Build
    // the same two-button frame twice: the fingerprints must differ within a
    // frame, each must map back to its own index, and both must be stable.
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    var fingerprints: [2][2]Fingerprint = undefined;
    for (&fingerprints) |*frame| {
        tree.beginFrame();
        for (frame, 0..) |*fingerprint, index| {
            const pushed = tree.pushElement(.{ .role = .button, .name = "Delete" });
            try std.testing.expectEqual(@as(u16, @intCast(index)), pushed);
            fingerprint.* = tree.getElement(pushed).?.fingerprint;
            const found = tree.current_fingerprint_map.find(fingerprint.*);
            try std.testing.expectEqual(@as(?u16, pushed), found);
            tree.popElement();
        }
        tree.endFrame();
    }

    try std.testing.expect(!fingerprints[0][0].eql(fingerprints[0][1]));
    try std.testing.expect(fingerprints[0][0].eql(fingerprints[1][0]));
    try std.testing.expect(fingerprints[0][1].eql(fingerprints[1][1]));
    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);
}

test "a fingerprint already held this frame is replaced by a free, stable variant" {
    // Siblings cannot collide, but subtrees whose parent contributions
    // coincide can. Force that case by asking for a fingerprint the frame
    // already holds: the result must be valid, free, and deterministic.
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    const held = tree.getElement(tree.pushElement(.{ .role = .button, .name = "Ok" })).?;
    tree.popElement();
    const variant = tree.uniqueFingerprint(held.fingerprint);
    try std.testing.expect(variant.isValid());
    try std.testing.expect(!variant.eql(held.fingerprint));
    try std.testing.expectEqual(@as(?u16, null), tree.current_fingerprint_map.find(variant));
    try std.testing.expect(variant.eql(tree.uniqueFingerprint(held.fingerprint)));
    tree.endFrame();
}

test "fingerprint map basic operations" {
    var map = try FingerprintMap.init(256);
    defer map.deinit(true);

    const fp1 = fingerprint_mod.compute(.button, "Button1", null, 0);
    const fp2 = fingerprint_mod.compute(.button, "Button2", null, 1);
    const fp3 = fingerprint_mod.compute(.checkbox, "Check", null, 0);

    try std.testing.expectEqual(@as(?u16, null), map.find(fp1));

    map.insert(fp1, 0);
    map.insert(fp2, 1);
    map.insert(fp3, 2);

    try std.testing.expectEqual(@as(?u16, 0), map.find(fp1));
    try std.testing.expectEqual(@as(?u16, 1), map.find(fp2));
    try std.testing.expectEqual(@as(?u16, 2), map.find(fp3));

    const fp_missing = fingerprint_mod.compute(.slider, "Missing", null, 0);
    try std.testing.expectEqual(@as(?u16, null), map.find(fp_missing));

    map.clear();
    try std.testing.expectEqual(@as(?u16, null), map.find(fp1));
    try std.testing.expectEqual(@as(?u16, null), map.find(fp2));
}

test "fingerprint map collision handling" {
    var map = try FingerprintMap.init(256);
    defer map.deinit(true);

    var fps: [100]Fingerprint = undefined;
    for (0..100) |i| {
        fps[i] = fingerprint_mod.compute(.button, "CollisionTest", null, @intCast(i));
        map.insert(fps[i], @intCast(i));
    }

    for (0..100) |i| {
        const found = map.find(fps[i]);
        try std.testing.expect(found != null);
        try std.testing.expectEqual(@as(u16, @intCast(i)), found.?);
    }
}

test "tree dirty detection uses hash map" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .group, .name = "Container" });
    for (0..50) |i| {
        _ = tree.pushElement(.{
            .role = .button,
            .name = if (i < 25) "ButtonA" else "ButtonB",
            .state = .{ .disabled = i % 2 == 0 },
        });
        tree.popElement();
    }
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 51), tree.dirty_count);

    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .group, .name = "Container" });
    for (0..50) |i| {
        _ = tree.pushElement(.{
            .role = .button,
            .name = if (i < 25) "ButtonA" else "ButtonB",
            .state = .{ .disabled = i % 2 == 0 },
        });
        tree.popElement();
    }
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);
}

test "live region auto-announcement on content change" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .status,
        .name = "Status",
        .value = "Ready",
    });
    tree.popElement();
    tree.endFrame();

    // New elements don't auto-announce; only content changes do.
    try std.testing.expectEqual(@as(u16, 0), tree.announcement_count);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .status,
        .name = "Status",
        .value = "Loading...",
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.announcement_count);
    const announcements = tree.getAnnouncements();
    try std.testing.expectEqualStrings("Loading...", announcements[0].message);
    try std.testing.expectEqual(types.Live.polite, announcements[0].live);
}

test "alert role auto-announces assertively" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .alert,
        .name = "Error",
        .value = "Something went wrong",
    });
    tree.popElement();
    tree.endFrame();

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .alert,
        .name = "Error",
        .value = "Connection lost",
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.announcement_count);
    const announcements = tree.getAnnouncements();
    try std.testing.expectEqualStrings("Connection lost", announcements[0].message);
    try std.testing.expectEqual(types.Live.assertive, announcements[0].live);
}

test "explicit live property overrides role default" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .group,
        .name = "Updates",
        .value = "No updates",
        .live = .assertive,
    });
    tree.popElement();
    tree.endFrame();

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .group,
        .name = "Updates",
        .value = "3 new messages",
        .live = .assertive,
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.announcement_count);
    const announcements = tree.getAnnouncements();
    try std.testing.expectEqual(types.Live.assertive, announcements[0].live);
}

test "non-live regions do not auto-announce" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Submit",
    });
    tree.popElement();
    tree.endFrame();

    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Cancel",
    });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 0), tree.announcement_count);
}

test "relationship fields propagate correctly" {
    const tree = try createTestTree();
    defer destroyTestTree(tree);
    tree.beginFrame();

    const label_idx = tree.pushElement(.{
        .role = .paragraph,
        .name = "Label",
    });
    tree.popElement();

    const desc_idx = tree.pushElement(.{
        .role = .paragraph,
        .name = "Description text",
    });
    tree.popElement();

    const target_idx = tree.pushElement(.{
        .role = .region,
        .name = "Target region",
    });
    tree.popElement();

    const main_idx = tree.pushElement(.{
        .role = .textbox,
        .name = "Input field",
        .labelled_by = label_idx,
        .described_by = desc_idx,
        .controls = target_idx,
    });
    tree.popElement();

    tree.endFrame();

    const main_elem = tree.getElement(main_idx).?;
    try std.testing.expectEqual(label_idx, main_elem.labelled_by);
    try std.testing.expectEqual(desc_idx, main_elem.described_by);
    try std.testing.expectEqual(target_idx, main_elem.controls);
}
