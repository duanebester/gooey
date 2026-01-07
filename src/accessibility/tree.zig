//! Accessibility tree - rebuilt each frame, synced to platform.
//!
//! Design:
//! - Fixed-size element pool (no allocation during render)
//! - Fingerprint-based identity for cross-frame correlation
//! - Dirty tracking to minimize platform sync overhead
//! - Deferred announcements batched per frame
//! - Hash map for O(1) fingerprint lookups (Phase 2 optimization)

const std = @import("std");
const constants = @import("constants.zig");
const element_mod = @import("element.zig");
const fingerprint_mod = @import("fingerprint.zig");
const types = @import("types.zig");
const layout = @import("../layout/layout.zig");
const engine_mod = @import("../layout/engine.zig");

pub const Element = element_mod.Element;
pub const Fingerprint = fingerprint_mod.Fingerprint;

/// Hash map for O(1) fingerprint → index lookups.
/// Uses open addressing with linear probing.
/// Bucket count is power of 2 for fast modulo via bitmask.
const FingerprintMap = struct {
    const BUCKET_COUNT: u16 = 4096; // Power of 2, ~2x MAX_ELEMENTS for low collision rate
    const BUCKET_MASK: u64 = BUCKET_COUNT - 1;
    const EMPTY: u16 = 0xFFFF; // Sentinel for empty bucket

    /// Maps hash bucket → element index (or EMPTY)
    buckets: [BUCKET_COUNT]u16 = [_]u16{EMPTY} ** BUCKET_COUNT,

    /// Fingerprints stored at each bucket (for collision resolution)
    fingerprints: [BUCKET_COUNT]Fingerprint = [_]Fingerprint{Fingerprint.INVALID} ** BUCKET_COUNT,

    const Self = @This();

    /// Insert fingerprint → index mapping
    pub fn insert(self: *Self, fp: Fingerprint, index: u16) void {
        std.debug.assert(fp.isValid());
        std.debug.assert(index < constants.MAX_ELEMENTS);

        var bucket = self.hash(fp);
        var probes: u16 = 0;

        while (probes < BUCKET_COUNT) : (probes += 1) {
            if (self.buckets[bucket] == EMPTY) {
                self.buckets[bucket] = index;
                self.fingerprints[bucket] = fp;
                return;
            }
            // Linear probe to next bucket
            bucket = (bucket + 1) & @as(u16, @truncate(BUCKET_MASK));
        }

        // Table full - should never happen with proper sizing
        // Fail fast per CLAUDE.md
        unreachable;
    }

    /// Find index for fingerprint, or null if not found
    pub fn find(self: *const Self, fp: Fingerprint) ?u16 {
        std.debug.assert(fp.isValid());

        var bucket = self.hash(fp);
        var probes: u16 = 0;

        while (probes < BUCKET_COUNT) : (probes += 1) {
            const stored_idx = self.buckets[bucket];
            if (stored_idx == EMPTY) {
                return null; // Not found
            }
            if (self.fingerprints[bucket].eql(fp)) {
                return stored_idx;
            }
            // Linear probe to next bucket
            bucket = (bucket + 1) & @as(u16, @truncate(BUCKET_MASK));
        }

        return null;
    }

    /// Clear all entries
    pub fn clear(self: *Self) void {
        @memset(&self.buckets, EMPTY);
        // No need to clear fingerprints - they're only valid when bucket != EMPTY
    }

    /// Hash fingerprint to bucket index
    fn hash(self: *const Self, fp: Fingerprint) u16 {
        _ = self;
        // Use fingerprint's u64 value directly - it's already well-distributed
        const fp_u64 = fp.toU64();
        // Mix high and low bits for better distribution
        const mixed = fp_u64 ^ (fp_u64 >> 32);
        return @truncate(mixed & BUCKET_MASK);
    }
};

pub const Tree = struct {
    // =========================================================================
    // Element Storage (static allocation)
    // =========================================================================

    /// Fixed-size element pool
    elements: [constants.MAX_ELEMENTS]Element = undefined,
    element_count: u16 = 0,

    /// Parent stack for tree construction
    parent_stack: [constants.MAX_DEPTH]u16 = undefined,
    stack_depth: u8 = 0,

    /// Child position counters (for fingerprinting)
    child_positions: [constants.MAX_DEPTH]u8 = undefined,

    // =========================================================================
    // Cross-Frame State
    // =========================================================================

    /// Previous frame's fingerprints (for identity correlation)
    prev_fingerprints: [constants.MAX_ELEMENTS]Fingerprint =
        [_]Fingerprint{Fingerprint.INVALID} ** constants.MAX_ELEMENTS,
    prev_count: u16 = 0,

    /// Previous frame's content hashes (for dirty detection)
    prev_hashes: [constants.MAX_ELEMENTS]u32 = [_]u32{0} ** constants.MAX_ELEMENTS,

    /// Hash map for O(1) previous fingerprint lookups
    prev_fingerprint_map: FingerprintMap = .{},

    /// Dirty element indices (need platform sync)
    dirty_indices: [constants.MAX_ELEMENTS]u16 = undefined,
    dirty_count: u16 = 0,

    /// Elements that existed last frame but not this frame (need removal)
    removed_fingerprints: [constants.MAX_ELEMENTS]Fingerprint = undefined,
    removed_count: u16 = 0,

    // =========================================================================
    // Announcements
    // =========================================================================

    announcements: [constants.MAX_ANNOUNCEMENTS]Announcement = undefined,
    announcement_count: u8 = 0,

    // =========================================================================
    // Frame State
    // =========================================================================

    /// Root element index (usually 0)
    root: ?u16 = null,

    /// Current frame's focused element (by fingerprint)
    focused_fingerprint: ?Fingerprint = null,

    /// Previous frame's focused fingerprint (for focus change detection)
    prev_focused_fingerprint: ?Fingerprint = null,

    /// Hash map for O(1) current frame fingerprint lookups
    current_fingerprint_map: FingerprintMap = .{},

    const Self = @This();

    pub const Announcement = struct {
        message: []const u8,
        live: types.Live,
    };

    // =========================================================================
    // Lifecycle
    // =========================================================================

    pub fn init() Self {
        return .{};
    }

    /// Initialize tree in-place using out-pointer pattern.
    /// Avoids stack overflow on WASM where Tree is ~350KB.
    /// Marked noinline to prevent stack accumulation in WASM builds.
    pub noinline fn initInPlace(self: *Self) void {
        // Zero all fields explicitly to avoid stack temporary
        self.element_count = 0;
        self.stack_depth = 0;
        self.prev_count = 0;
        self.dirty_count = 0;
        self.removed_count = 0;
        self.announcement_count = 0;
        self.root = null;
        self.focused_fingerprint = null;
        self.prev_focused_fingerprint = null;

        // Zero large arrays using @memset (no stack allocation)
        @memset(&self.prev_fingerprints, Fingerprint.INVALID);
        @memset(&self.prev_hashes, 0);

        // Clear hash maps
        self.prev_fingerprint_map.clear();
        self.current_fingerprint_map.clear();
    }

    /// Reset for new frame. Preserves cross-frame state.
    pub fn beginFrame(self: *Self) void {
        // Assertion: element_count should be within bounds
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);
        // Assertion: stack should be balanced from previous frame
        std.debug.assert(self.stack_depth == 0);

        // Snapshot current frame for diff
        self.prev_count = self.element_count;
        self.prev_focused_fingerprint = self.focused_fingerprint;

        // Clear and rebuild previous fingerprint map
        // Only copy the used portion (Phase 2.2 optimization)
        self.prev_fingerprint_map.clear();
        const elem_count = self.element_count;
        for (0..elem_count) |i| {
            const elem = &self.elements[i];
            self.prev_fingerprints[i] = elem.fingerprint;
            self.prev_hashes[i] = elem.contentHash();
            // Build hash map for O(1) lookups during dirty detection
            if (elem.fingerprint.isValid()) {
                self.prev_fingerprint_map.insert(elem.fingerprint, @intCast(i));
            }
        }

        // Reset current frame
        self.element_count = 0;
        self.stack_depth = 0;
        self.dirty_count = 0;
        self.removed_count = 0;
        self.announcement_count = 0;
        self.root = null;
        self.focused_fingerprint = null;

        // Clear current frame fingerprint map
        self.current_fingerprint_map.clear();
    }

    /// Finalize frame. Computes dirty set and removals.
    pub fn endFrame(self: *Self) void {
        // Assertion: stack must be balanced
        std.debug.assert(self.stack_depth == 0);
        // Assertion: element count within bounds
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        self.computeDirtyElements();
        self.computeRemovedElements();
    }

    /// Find dirty elements (content changed or new)
    /// Uses hash map for O(n) total instead of O(n²)
    /// Phase 3.3: Auto-announces live region content changes
    fn computeDirtyElements(self: *Self) void {
        std.debug.assert(self.dirty_count == 0); // Should be reset in beginFrame
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        const elem_count = self.element_count;
        for (0..elem_count) |i| {
            const elem = &self.elements[i];
            const current_hash = elem.contentHash();

            // O(1) lookup using hash map instead of O(n) scan
            const prev_idx = self.prev_fingerprint_map.find(elem.fingerprint);

            if (prev_idx) |pi| {
                // Element existed - check if content changed
                if (self.prev_hashes[pi] != current_hash) {
                    self.markDirty(@intCast(i));

                    // Phase 3.3: Auto-announce live region content changes
                    // When a live region's content changes, automatically announce it
                    self.autoAnnounceLiveRegion(elem);
                }
            } else {
                // New element - always dirty
                self.markDirty(@intCast(i));
            }
        }
    }

    /// Phase 3.3: Auto-announce content changes for live regions
    /// Called when a live region element's content hash changes
    fn autoAnnounceLiveRegion(self: *Self, elem: *const Element) void {
        // Check if this is a live region (explicit live property or role-based)
        const live_level = elem.effectiveLive();
        if (live_level == .off) return;

        // Get the content to announce - prefer value, then name
        const content = elem.value orelse elem.name orelse return;
        if (content.len == 0) return;

        // Queue the announcement with appropriate priority
        self.announce(content, live_level);
    }

    /// Find removed elements (existed before, not now)
    /// Uses hash map for O(n) total instead of O(n²)
    fn computeRemovedElements(self: *Self) void {
        std.debug.assert(self.removed_count == 0); // Should be reset in beginFrame
        std.debug.assert(self.prev_count <= constants.MAX_ELEMENTS);

        const prev_elem_count = self.prev_count;
        for (0..prev_elem_count) |i| {
            const prev_fp = self.prev_fingerprints[i];
            if (!prev_fp.isValid()) continue;

            // O(1) lookup using hash map instead of O(n) scan
            const found = self.current_fingerprint_map.find(prev_fp) != null;

            if (!found and self.removed_count < constants.MAX_ELEMENTS) {
                self.removed_fingerprints[self.removed_count] = prev_fp;
                self.removed_count += 1;
            }
        }
    }

    /// Find element in previous frame by fingerprint (O(1) via hash map)
    fn findPrevByFingerprint(self: *const Self, fp: Fingerprint) ?u16 {
        std.debug.assert(fp.isValid());
        return self.prev_fingerprint_map.find(fp);
    }

    /// Find element in current frame by fingerprint (O(1) via hash map)
    fn findElementByFingerprint(self: *const Self, fp: Fingerprint) ?u16 {
        std.debug.assert(fp.isValid());
        return self.current_fingerprint_map.find(fp);
    }

    fn markDirty(self: *Self, index: u16) void {
        std.debug.assert(index < self.element_count);
        std.debug.assert(self.dirty_count <= constants.MAX_ELEMENTS);

        if (self.dirty_count >= constants.MAX_ELEMENTS) return;
        self.dirty_indices[self.dirty_count] = index;
        self.dirty_count += 1;
    }

    // =========================================================================
    // Tree Construction (called during render)
    // =========================================================================

    /// Begin an accessible element. Call at component open.
    /// Returns element index or null if tree is full.
    pub fn pushElement(self: *Self, config: ElementConfig) ?u16 {
        // Assertion: not exceeding element limit
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);
        // Assertion: not exceeding depth limit
        std.debug.assert(self.stack_depth <= constants.MAX_DEPTH);

        if (self.element_count >= constants.MAX_ELEMENTS) {
            // Tree full - fail gracefully per CLAUDE.md
            return null;
        }
        if (self.stack_depth >= constants.MAX_DEPTH) {
            return null;
        }

        const index = self.element_count;
        const parent_idx = self.currentParent();

        // Get position in parent for fingerprint
        const position: u8 = if (self.stack_depth > 0) blk: {
            const pos = self.child_positions[self.stack_depth - 1];
            self.child_positions[self.stack_depth - 1] = pos +| 1; // saturating add
            break :blk pos;
        } else 0;

        // Get parent fingerprint
        const parent_fp: ?Fingerprint = if (parent_idx) |pi|
            self.elements[pi].fingerprint
        else
            null;

        // Compute fingerprint
        const fp = fingerprint_mod.compute(
            config.role,
            config.name,
            parent_fp,
            position,
        );

        // Initialize element
        self.elements[index] = .{
            .layout_id = config.layout_id,
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
            .pos_in_set = config.pos_in_set,
            .set_size = config.set_size,
            .parent = parent_idx,
            // Relationships
            .labelled_by = config.labelled_by,
            .described_by = config.described_by,
            .controls = config.controls,
        };

        // Add to current frame fingerprint map for O(1) lookups
        if (fp.isValid()) {
            self.current_fingerprint_map.insert(fp, index);
        }

        self.linkToParent(index, parent_idx);
        self.trackFocus(index, config.state.focused, fp);
        self.advanceStack(index);

        return index;
    }

    /// Link new element to its parent in the tree structure
    fn linkToParent(self: *Self, index: u16, parent_idx: ?u16) void {
        std.debug.assert(index < constants.MAX_ELEMENTS);
        std.debug.assert(parent_idx == null or parent_idx.? < index);

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

    /// Track focused element by fingerprint
    fn trackFocus(self: *Self, index: u16, is_focused: bool, fp: Fingerprint) void {
        std.debug.assert(index < constants.MAX_ELEMENTS);
        std.debug.assert(fp.isValid());

        if (is_focused) {
            self.focused_fingerprint = fp;
        }
    }

    /// Push element onto parent stack
    fn advanceStack(self: *Self, index: u16) void {
        std.debug.assert(self.stack_depth < constants.MAX_DEPTH);
        std.debug.assert(index < constants.MAX_ELEMENTS);

        self.parent_stack[self.stack_depth] = index;
        self.child_positions[self.stack_depth] = 0;
        self.stack_depth += 1;
        self.element_count += 1;
    }

    /// End current accessible element. Call at component close.
    pub fn popElement(self: *Self) void {
        std.debug.assert(self.stack_depth > 0);
        std.debug.assert(self.element_count > 0);

        self.stack_depth -= 1;
    }

    /// Get current parent index (top of stack)
    fn currentParent(self: *const Self) ?u16 {
        std.debug.assert(self.stack_depth <= constants.MAX_DEPTH);

        if (self.stack_depth == 0) return null;
        return self.parent_stack[self.stack_depth - 1];
    }

    // =========================================================================
    // Announcements
    // =========================================================================

    /// Queue a message for screen reader announcement.
    pub fn announce(self: *Self, message: []const u8, live: types.Live) void {
        // Assertion: live level is valid
        std.debug.assert(@intFromEnum(live) <= @intFromEnum(types.Live.assertive));
        // Assertion: announcement count is within bounds
        std.debug.assert(self.announcement_count <= constants.MAX_ANNOUNCEMENTS);

        if (live == .off) return;
        if (self.announcement_count >= constants.MAX_ANNOUNCEMENTS) return;

        self.announcements[self.announcement_count] = .{
            .message = message,
            .live = live,
        };
        self.announcement_count += 1;
    }

    // =========================================================================
    // Queries
    // =========================================================================

    /// Get element by index
    pub fn getElement(self: *const Self, index: u16) ?*const Element {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        if (index >= self.element_count) return null;
        return &self.elements[index];
    }

    /// Get mutable element by index
    pub fn getElementMut(self: *Self, index: u16) ?*Element {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        if (index >= self.element_count) return null;
        return &self.elements[index];
    }

    /// Get indices of dirty elements (changed this frame)
    pub fn getDirtyElements(self: *const Self) []const u16 {
        std.debug.assert(self.dirty_count <= constants.MAX_ELEMENTS);
        return self.dirty_indices[0..self.dirty_count];
    }

    /// Get fingerprints of removed elements
    pub fn getRemovedFingerprints(self: *const Self) []const Fingerprint {
        std.debug.assert(self.removed_count <= constants.MAX_ELEMENTS);
        return self.removed_fingerprints[0..self.removed_count];
    }

    /// Get pending announcements
    pub fn getAnnouncements(self: *const Self) []const Announcement {
        std.debug.assert(self.announcement_count <= constants.MAX_ANNOUNCEMENTS);
        return self.announcements[0..self.announcement_count];
    }

    /// Get element count
    pub fn count(self: *const Self) u16 {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);
        return self.element_count;
    }

    /// Get root element index
    pub fn getRoot(self: *const Self) ?u16 {
        return self.root;
    }

    /// Check if focus changed this frame
    pub fn focusChanged(self: *const Self) bool {
        const prev = self.prev_focused_fingerprint;
        const curr = self.focused_fingerprint;

        if (prev == null and curr == null) return false;
        if (prev == null or curr == null) return true;
        return !prev.?.eql(curr.?);
    }

    /// Get index of currently focused element (if any)
    pub fn getFocusedIndex(self: *const Self) ?u16 {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        const fp = self.focused_fingerprint orelse return null;
        return self.findElementByFingerprint(fp);
    }

    /// Check if tree is empty
    pub fn isEmpty(self: *const Self) bool {
        return self.element_count == 0;
    }

    /// Find element by layout_id (for resolving relationship IDs).
    /// Returns element index if found, null otherwise.
    /// Note: This is O(n) - use sparingly, primarily for relationship resolution.
    pub fn findElementByLayoutId(self: *const Self, layout_id: layout.LayoutId) ?u16 {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        if (layout_id.id == 0) return null;

        const elem_count = self.element_count;
        for (0..elem_count) |i| {
            if (self.elements[i].layout_id.id == layout_id.id) {
                return @intCast(i);
            }
        }
        return null;
    }

    /// Find element by string ID (convenience wrapper).
    /// Converts string to LayoutId and searches.
    pub fn findElementByStringId(self: *const Self, id: []const u8) ?u16 {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        if (id.len == 0) return null;

        const layout_id = layout.LayoutId.fromString(id);
        return self.findElementByLayoutId(layout_id);
    }

    /// Check if tree has capacity for more elements
    pub fn hasCapacity(self: *const Self) bool {
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);
        return self.element_count < constants.MAX_ELEMENTS;
    }

    // =========================================================================
    // Layout Sync
    // =========================================================================

    /// Sync bounds from layout engine to accessibility elements.
    /// Call after layout computation, before platform sync.
    pub fn syncBounds(self: *Self, layout_engine: *const engine_mod.LayoutEngine) void {
        // Assertion: element count is bounded
        std.debug.assert(self.element_count <= constants.MAX_ELEMENTS);

        const elem_count = self.element_count;
        for (0..elem_count) |i| {
            const elem = &self.elements[i];

            // Skip elements without layout_id
            if (elem.layout_id.id == 0) continue;

            // Look up bounds from layout engine
            if (layout_engine.getBoundingBox(elem.layout_id.id)) |bounds| {
                elem.bounds = bounds;
            }
        }
    }
};

/// Configuration for pushElement()
pub const ElementConfig = struct {
    layout_id: layout.LayoutId = layout.LayoutId.none,
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
    pos_in_set: ?u16 = null,
    set_size: ?u16 = null,

    // =========================================================================
    // Relationships (indices into element pool)
    // =========================================================================

    /// Element that labels this one (for aria-labelledby)
    labelled_by: ?u16 = null,

    /// Element that describes this one (for aria-describedby)
    described_by: ?u16 = null,

    /// Element this one controls (for aria-controls)
    controls: ?u16 = null,
};

// Compile-time assertions per CLAUDE.md
comptime {
    // Tree should have reasonable size (mostly arrays with known bounds)
    // Each array is sized by constants, total should be manageable
    // Note: Size increased due to FingerprintMap additions (~50KB extra)
    const tree_size = @sizeOf(Tree);
    std.debug.assert(tree_size < 2 * 1024 * 1024); // Less than 2MB

    // ElementConfig should be small for stack passing
    // Size increased to accommodate relationship fields (labelled_by, described_by, controls)
    std.debug.assert(@sizeOf(ElementConfig) <= 160);

    // FingerprintMap should be reasonably sized
    const map_size = @sizeOf(FingerprintMap);
    std.debug.assert(map_size < 64 * 1024); // Less than 64KB per map

    // Bucket count must be power of 2 for bitmask optimization
    std.debug.assert(FingerprintMap.BUCKET_COUNT & (FingerprintMap.BUCKET_COUNT - 1) == 0);
}

test "tree basic operations" {
    var tree = Tree.init();
    tree.beginFrame();

    const idx = tree.pushElement(.{
        .role = .button,
        .name = "Submit",
    });

    try std.testing.expect(idx != null);
    try std.testing.expectEqual(@as(u16, 1), tree.count());

    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u8, 0), tree.stack_depth);
}

test "tree parent-child relationships" {
    var tree = Tree.init();
    tree.beginFrame();

    const parent_idx = tree.pushElement(.{
        .role = .group,
        .name = "Container",
    }).?;

    const child1_idx = tree.pushElement(.{
        .role = .button,
        .name = "Button 1",
    }).?;
    tree.popElement();

    const child2_idx = tree.pushElement(.{
        .role = .button,
        .name = "Button 2",
    }).?;
    tree.popElement();

    tree.popElement(); // Close parent

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
    var tree = Tree.init();

    // Frame 1: Create initial tree
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    // All new elements should be dirty
    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);

    // Frame 2: Same content
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();
    tree.endFrame();

    // No changes, nothing dirty
    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);

    // Frame 3: Changed name
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Cancel" });
    tree.popElement();
    tree.endFrame();

    // Name changed - should be dirty (actually this is a NEW element due to fingerprint)
    try std.testing.expectEqual(@as(u16, 1), tree.dirty_count);
}

test "tree removal tracking" {
    var tree = Tree.init();

    // Frame 1: Two buttons
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 2), tree.count());

    // Frame 2: Only one button
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(u16, 1), tree.count());
    try std.testing.expectEqual(@as(u16, 1), tree.removed_count);
}

test "tree announcements" {
    var tree = Tree.init();
    tree.beginFrame();

    tree.announce("File saved", .polite);
    tree.announce("Error occurred", .assertive);

    try std.testing.expectEqual(@as(u8, 2), tree.announcement_count);

    const announcements = tree.getAnnouncements();
    try std.testing.expectEqual(@as(usize, 2), announcements.len);
    try std.testing.expectEqualStrings("File saved", announcements[0].message);
    try std.testing.expectEqual(types.Live.polite, announcements[0].live);
    try std.testing.expectEqualStrings("Error occurred", announcements[1].message);
    try std.testing.expectEqual(types.Live.assertive, announcements[1].live);

    tree.endFrame();
}

test "tree focus tracking" {
    var tree = Tree.init();

    // Frame 1: No focus
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Button" });
    tree.popElement();
    tree.endFrame();

    try std.testing.expectEqual(@as(?u16, null), tree.getFocusedIndex());
    try std.testing.expect(!tree.focusChanged());

    // Frame 2: Button focused
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

    // Frame 3: Same focus
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
    var tree = Tree.init();
    tree.beginFrame();

    tree.announce("This should be ignored", .off);

    try std.testing.expectEqual(@as(u8, 0), tree.announcement_count);
}

test "tree fingerprint stability across frames" {
    var tree = Tree.init();

    // Capture fingerprint from frame 1
    tree.beginFrame();
    const idx1 = tree.pushElement(.{ .role = .button, .name = "Stable" }).?;
    const fp1 = tree.getElement(idx1).?.fingerprint;
    tree.popElement();
    tree.endFrame();

    // Same structure in frame 2 should have same fingerprint
    tree.beginFrame();
    const idx2 = tree.pushElement(.{ .role = .button, .name = "Stable" }).?;
    const fp2 = tree.getElement(idx2).?.fingerprint;
    tree.popElement();
    tree.endFrame();

    try std.testing.expect(fp1.eql(fp2));
}

test "fingerprint map basic operations" {
    var map = FingerprintMap{};

    const fp1 = fingerprint_mod.compute(.button, "Button1", null, 0);
    const fp2 = fingerprint_mod.compute(.button, "Button2", null, 1);
    const fp3 = fingerprint_mod.compute(.checkbox, "Check", null, 0);

    // Initially empty
    try std.testing.expectEqual(@as(?u16, null), map.find(fp1));

    // Insert and find
    map.insert(fp1, 0);
    map.insert(fp2, 1);
    map.insert(fp3, 2);

    try std.testing.expectEqual(@as(?u16, 0), map.find(fp1));
    try std.testing.expectEqual(@as(?u16, 1), map.find(fp2));
    try std.testing.expectEqual(@as(?u16, 2), map.find(fp3));

    // Non-existent fingerprint
    const fp_missing = fingerprint_mod.compute(.slider, "Missing", null, 0);
    try std.testing.expectEqual(@as(?u16, null), map.find(fp_missing));

    // Clear and verify empty
    map.clear();
    try std.testing.expectEqual(@as(?u16, null), map.find(fp1));
    try std.testing.expectEqual(@as(?u16, null), map.find(fp2));
}

test "fingerprint map collision handling" {
    var map = FingerprintMap{};

    // Insert many elements to test collision handling
    var fps: [100]Fingerprint = undefined;
    for (0..100) |i| {
        fps[i] = fingerprint_mod.compute(.button, "CollisionTest", null, @intCast(i));
        map.insert(fps[i], @intCast(i));
    }

    // All should be findable despite potential collisions
    for (0..100) |i| {
        const found = map.find(fps[i]);
        try std.testing.expect(found != null);
        try std.testing.expectEqual(@as(u16, @intCast(i)), found.?);
    }
}

test "tree dirty detection uses hash map" {
    var tree = Tree.init();

    // Frame 1: Create elements inside a parent (so they get unique positions)
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
    tree.popElement(); // Close container
    tree.endFrame();

    // All new = all dirty (51 elements: 1 container + 50 buttons)
    try std.testing.expectEqual(@as(u16, 51), tree.dirty_count);

    // Frame 2: Same content - should be O(n) not O(n²) now
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
    tree.popElement(); // Close container
    tree.endFrame();

    // Nothing changed
    try std.testing.expectEqual(@as(u16, 0), tree.dirty_count);
}

test "live region auto-announcement on content change" {
    var tree = Tree.init();

    // Frame 1: Create a status live region
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .status,
        .name = "Status",
        .value = "Ready",
    });
    tree.popElement();
    tree.endFrame();

    // New elements don't auto-announce (they're just created)
    try std.testing.expectEqual(@as(u8, 0), tree.announcement_count);

    // Frame 2: Change the status content
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .status,
        .name = "Status",
        .value = "Loading...",
    });
    tree.popElement();
    tree.endFrame();

    // Content change should trigger auto-announcement
    try std.testing.expectEqual(@as(u8, 1), tree.announcement_count);
    const announcements = tree.getAnnouncements();
    try std.testing.expectEqualStrings("Loading...", announcements[0].message);
    try std.testing.expectEqual(types.Live.polite, announcements[0].live);
}

test "alert role auto-announces assertively" {
    var tree = Tree.init();

    // Frame 1: Create an alert
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .alert,
        .name = "Error",
        .value = "Something went wrong",
    });
    tree.popElement();
    tree.endFrame();

    // Frame 2: Change alert content
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .alert,
        .name = "Error",
        .value = "Connection lost",
    });
    tree.popElement();
    tree.endFrame();

    // Alert should announce assertively
    try std.testing.expectEqual(@as(u8, 1), tree.announcement_count);
    const announcements = tree.getAnnouncements();
    try std.testing.expectEqualStrings("Connection lost", announcements[0].message);
    try std.testing.expectEqual(types.Live.assertive, announcements[0].live);
}

test "explicit live property overrides role default" {
    var tree = Tree.init();

    // Frame 1: Create a group with explicit live=assertive
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .group,
        .name = "Updates",
        .value = "No updates",
        .live = .assertive,
    });
    tree.popElement();
    tree.endFrame();

    // Frame 2: Change content
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .group,
        .name = "Updates",
        .value = "3 new messages",
        .live = .assertive,
    });
    tree.popElement();
    tree.endFrame();

    // Should use explicit live level
    try std.testing.expectEqual(@as(u8, 1), tree.announcement_count);
    const announcements = tree.getAnnouncements();
    try std.testing.expectEqual(types.Live.assertive, announcements[0].live);
}

test "non-live regions do not auto-announce" {
    var tree = Tree.init();

    // Frame 1: Create a regular button
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Submit",
    });
    tree.popElement();
    tree.endFrame();

    // Frame 2: Change button name
    tree.beginFrame();
    _ = tree.pushElement(.{
        .role = .button,
        .name = "Cancel",
    });
    tree.popElement();
    tree.endFrame();

    // Regular elements don't auto-announce
    try std.testing.expectEqual(@as(u8, 0), tree.announcement_count);
}

test "findElementByLayoutId returns correct index" {
    var tree = Tree.init();
    tree.beginFrame();

    const label_id = layout.LayoutId.fromString("name-label");
    const input_id = layout.LayoutId.fromString("name-input");

    // Create label element first
    const label_idx = tree.pushElement(.{
        .layout_id = label_id,
        .role = .paragraph,
        .name = "Name:",
    });
    tree.popElement();

    // Create input element with relationship to label
    const input_idx = tree.pushElement(.{
        .layout_id = input_id,
        .role = .textbox,
        .name = "Name input",
        .labelled_by = label_idx,
    });
    tree.popElement();

    tree.endFrame();

    // Verify findElementByLayoutId works
    try std.testing.expectEqual(label_idx, tree.findElementByLayoutId(label_id));
    try std.testing.expectEqual(input_idx, tree.findElementByLayoutId(input_id));

    // Verify findElementByStringId works
    try std.testing.expectEqual(label_idx, tree.findElementByStringId("name-label"));
    try std.testing.expectEqual(input_idx, tree.findElementByStringId("name-input"));

    // Verify relationship is set correctly
    const input_elem = tree.getElement(input_idx.?).?;
    try std.testing.expectEqual(label_idx, input_elem.labelled_by);

    // Non-existent ID returns null
    try std.testing.expectEqual(@as(?u16, null), tree.findElementByStringId("non-existent"));
    try std.testing.expectEqual(@as(?u16, null), tree.findElementByLayoutId(layout.LayoutId.none));
}

test "relationship fields propagate correctly" {
    var tree = Tree.init();
    tree.beginFrame();

    // Create elements with all relationship types
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

    // Create element with all relationships
    const main_idx = tree.pushElement(.{
        .role = .textbox,
        .name = "Input field",
        .labelled_by = label_idx,
        .described_by = desc_idx,
        .controls = target_idx,
    });
    tree.popElement();

    tree.endFrame();

    // Verify all relationships are set
    const main_elem = tree.getElement(main_idx.?).?;
    try std.testing.expectEqual(label_idx, main_elem.labelled_by);
    try std.testing.expectEqual(desc_idx, main_elem.described_by);
    try std.testing.expectEqual(target_idx, main_elem.controls);
}
