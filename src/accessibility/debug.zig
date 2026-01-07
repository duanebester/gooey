//! Accessibility Debug & Inspection Tools
//!
//! Provides utilities for debugging and testing accessibility implementations:
//! - Tree dumping for visual inspection
//! - Element validation
//! - Statistics and metrics
//! - Test helpers
//!
//! Usage:
//! ```zig
//! const debug = @import("accessibility/debug.zig");
//!
//! // Dump tree to debug output
//! debug.dumpTree(&a11y_tree);
//!
//! // Get tree statistics
//! const stats = debug.getStats(&a11y_tree);
//!
//! // Validate tree structure
//! const issues = debug.validate(&a11y_tree);
//! ```

const std = @import("std");
const builtin = @import("builtin");

const tree_mod = @import("tree.zig");
const element_mod = @import("element.zig");
const types = @import("types.zig");
const constants = @import("constants.zig");
const fingerprint_mod = @import("fingerprint.zig");

pub const Tree = tree_mod.Tree;
pub const Element = element_mod.Element;
pub const Role = types.Role;
pub const State = types.State;
pub const Fingerprint = fingerprint_mod.Fingerprint;

/// Statistics about the accessibility tree
pub const TreeStats = struct {
    /// Total number of elements
    element_count: usize,
    /// Number of dirty (changed) elements this frame
    dirty_count: usize,
    /// Number of removed elements this frame
    removed_count: usize,
    /// Number of pending announcements
    announcement_count: usize,
    /// Maximum depth reached
    max_depth: usize,
    /// Number of focusable elements
    focusable_count: usize,
    /// Number of elements by role
    role_counts: [256]usize,

    pub fn init() TreeStats {
        return .{
            .element_count = 0,
            .dirty_count = 0,
            .removed_count = 0,
            .announcement_count = 0,
            .max_depth = 0,
            .focusable_count = 0,
            .role_counts = [_]usize{0} ** 256,
        };
    }
};

/// Validation issue found in the tree
pub const ValidationIssue = struct {
    element_index: usize,
    issue_type: IssueType,
    message: []const u8,

    pub const IssueType = enum {
        missing_name,
        invalid_parent,
        orphaned_element,
        invalid_heading_level,
        missing_set_info,
        duplicate_fingerprint,
        excessive_depth,
    };
};

/// Maximum issues to track
pub const MAX_ISSUES = 64;

/// Validation results
pub const ValidationResult = struct {
    issues: [MAX_ISSUES]ValidationIssue,
    issue_count: usize,
    is_valid: bool,

    pub fn init() ValidationResult {
        return .{
            .issues = undefined,
            .issue_count = 0,
            .is_valid = true,
        };
    }

    pub fn addIssue(self: *ValidationResult, index: usize, issue_type: ValidationIssue.IssueType, message: []const u8) void {
        if (self.issue_count >= MAX_ISSUES) return;

        self.issues[self.issue_count] = .{
            .element_index = index,
            .issue_type = issue_type,
            .message = message,
        };
        self.issue_count += 1;
        self.is_valid = false;
    }

    pub fn getIssues(self: *const ValidationResult) []const ValidationIssue {
        return self.issues[0..self.issue_count];
    }
};

/// Collect statistics about the accessibility tree
pub fn getStats(tree: *const Tree) TreeStats {
    var stats = TreeStats.init();

    stats.element_count = tree.element_count;
    stats.dirty_count = tree.dirty_count;
    stats.removed_count = tree.removed_count;
    stats.announcement_count = tree.announcement_count;

    // Analyze elements
    for (tree.elements[0..tree.element_count]) |elem| {
        // Count by role
        const role_idx = @intFromEnum(elem.role);
        stats.role_counts[role_idx] += 1;

        // Count focusable
        if (elem.isFocusable()) {
            stats.focusable_count += 1;
        }
    }

    // Calculate max depth (simple approximation from parent chain)
    for (tree.elements[0..tree.element_count]) |elem| {
        var depth: usize = 0;
        var current_parent = elem.parent;
        while (current_parent) |p_idx| {
            depth += 1;
            if (depth > constants.MAX_DEPTH) break;
            if (p_idx >= tree.element_count) break;
            current_parent = tree.elements[p_idx].parent;
        }
        if (depth > stats.max_depth) {
            stats.max_depth = depth;
        }
    }

    return stats;
}

/// Validate the accessibility tree structure
pub fn validate(tree: *const Tree) ValidationResult {
    var result = ValidationResult.init();

    // Check each element
    for (tree.elements[0..tree.element_count], 0..) |elem, i| {
        // Check for missing names on interactive elements
        if (elem.role.isFocusableByDefault() and elem.name == null) {
            result.addIssue(i, .missing_name, "Interactive element missing accessible name");
        }

        // Check parent validity
        if (elem.parent) |p_idx| {
            if (p_idx >= tree.element_count) {
                result.addIssue(i, .invalid_parent, "Element has invalid parent index");
            }
        }

        // Check heading level
        if (elem.role == .heading and elem.heading_level == 0) {
            result.addIssue(i, .invalid_heading_level, "Heading element missing heading_level");
        }

        // Check set info for relevant roles
        if (elem.role == .tab or elem.role == .option or elem.role == .treeitem) {
            if (elem.pos_in_set == null or elem.set_size == null) {
                result.addIssue(i, .missing_set_info, "Collection item missing pos_in_set/set_size");
            }
        }
    }

    // Check for duplicate fingerprints
    for (tree.elements[0..tree.element_count], 0..) |elem, i| {
        for (tree.elements[i + 1 .. tree.element_count], i + 1..) |other, j| {
            if (elem.fingerprint.eql(other.fingerprint)) {
                result.addIssue(j, .duplicate_fingerprint, "Duplicate fingerprint detected");
                break;
            }
        }
    }

    // Check depth
    if (tree.stack_depth > constants.MAX_DEPTH) {
        result.addIssue(0, .excessive_depth, "Tree depth exceeds maximum");
    }

    return result;
}

/// Dump the accessibility tree to debug output
pub fn dumpTree(tree: *const Tree) void {
    const writer = std.io.getStdErr().writer();
    dumpTreeTo(tree, writer) catch {};
}

/// Dump the accessibility tree to a specific writer
pub fn dumpTreeTo(tree: *const Tree, writer: anytype) !void {
    try writer.print("\n=== Accessibility Tree Dump ===\n", .{});
    try writer.print("Elements: {d}/{d}, Dirty: {d}, Removed: {d}\n", .{
        tree.element_count,
        constants.MAX_ELEMENTS,
        tree.dirty_count,
        tree.removed_count,
    });
    try writer.print("Stack depth: {d}/{d}\n", .{
        tree.stack_depth,
        constants.MAX_DEPTH,
    });

    if (tree.focused_fingerprint.toU64() != Fingerprint.INVALID.toU64()) {
        try writer.print("Focused: 0x{x:0>16}\n", .{tree.focused_fingerprint.toU64()});
    }

    try writer.print("\n--- Elements ---\n", .{});

    for (tree.elements[0..tree.element_count], 0..) |elem, i| {
        try dumpElementTo(elem, i, tree, writer);
    }

    if (tree.announcement_count > 0) {
        try writer.print("\n--- Announcements ---\n", .{});
        for (tree.announcements[0..tree.announcement_count]) |ann| {
            try writer.print("  [{s}] {s}\n", .{
                @tagName(ann.live),
                ann.message,
            });
        }
    }

    try writer.print("\n=== End Tree Dump ===\n\n", .{});
}

/// Dump a single element
fn dumpElementTo(elem: Element, index: usize, tree: *const Tree, writer: anytype) !void {
    // Calculate indent based on depth
    var depth: usize = 0;
    var current_parent = elem.parent;
    while (current_parent) |p_idx| {
        depth += 1;
        if (depth > 20) break; // Safety limit
        if (p_idx >= tree.element_count) break;
        current_parent = tree.elements[p_idx].parent;
    }

    // Indent
    for (0..depth) |_| {
        try writer.print("  ", .{});
    }

    // Role
    try writer.print("[{d}] {s}", .{ index, @tagName(elem.role) });

    // Name
    if (elem.name) |name| {
        try writer.print(": \"{s}\"", .{name});
    }

    // State flags
    var state_parts: [16][]const u8 = undefined;
    var state_count: usize = 0;

    if (elem.state.focused) {
        state_parts[state_count] = "focused";
        state_count += 1;
    }
    if (elem.state.selected) {
        state_parts[state_count] = "selected";
        state_count += 1;
    }
    if (elem.state.checked) {
        state_parts[state_count] = "checked";
        state_count += 1;
    }
    if (elem.state.expanded) {
        state_parts[state_count] = "expanded";
        state_count += 1;
    }
    if (elem.state.disabled) {
        state_parts[state_count] = "disabled";
        state_count += 1;
    }
    if (elem.state.busy) {
        state_parts[state_count] = "busy";
        state_count += 1;
    }
    if (elem.state.hidden) {
        state_parts[state_count] = "hidden";
        state_count += 1;
    }

    if (state_count > 0) {
        try writer.print(" [", .{});
        for (state_parts[0..state_count], 0..) |part, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("{s}", .{part});
        }
        try writer.print("]", .{});
    }

    // Value
    if (elem.value) |value| {
        try writer.print(" value=\"{s}\"", .{value});
    }

    // Range values
    if (elem.value_now) |now| {
        try writer.print(" now={d:.1}", .{now});
        if (elem.value_min) |min| {
            try writer.print(" min={d:.1}", .{min});
        }
        if (elem.value_max) |max| {
            try writer.print(" max={d:.1}", .{max});
        }
    }

    // Set position
    if (elem.pos_in_set) |pos| {
        if (elem.set_size) |size| {
            try writer.print(" ({d}/{d})", .{ pos, size });
        }
    }

    // Heading level
    if (elem.heading_level > 0) {
        try writer.print(" h{d}", .{elem.heading_level});
    }

    // Live region
    if (elem.live != .off) {
        try writer.print(" live={s}", .{@tagName(elem.live)});
    }

    // Fingerprint (abbreviated)
    try writer.print(" fp=0x{x:0>8}", .{@as(u32, @truncate(elem.fingerprint.toU64()))});

    try writer.print("\n", .{});
}

/// Format an element as a single-line summary string
pub fn formatElement(elem: *const Element, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    writer.print("{s}", .{@tagName(elem.role)}) catch return buf[0..0];

    if (elem.name) |name| {
        const truncated = if (name.len > 20) name[0..20] else name;
        writer.print(": \"{s}\"", .{truncated}) catch {};
        if (name.len > 20) {
            writer.print("...", .{}) catch {};
        }
    }

    return fbs.getWritten();
}

/// Get a human-readable state description
pub fn formatState(state: State, buf: []u8) []const u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();

    var first = true;
    inline for (std.meta.fields(State)) |field| {
        if (field.type == bool) {
            if (@field(state, field.name)) {
                if (!first) {
                    writer.print(", ", .{}) catch {};
                }
                writer.print("{s}", .{field.name}) catch {};
                first = false;
            }
        }
    }

    if (first) {
        writer.print("(none)", .{}) catch {};
    }

    return fbs.getWritten();
}

/// Count elements with a specific role
pub fn countByRole(tree: *const Tree, role: Role) usize {
    var count: usize = 0;
    for (tree.elements[0..tree.element_count]) |elem| {
        if (elem.role == role) {
            count += 1;
        }
    }
    return count;
}

/// Find element by name (first match)
pub fn findByName(tree: *const Tree, name: []const u8) ?*const Element {
    for (tree.elements[0..tree.element_count]) |*elem| {
        if (elem.name) |elem_name| {
            if (std.mem.eql(u8, elem_name, name)) {
                return elem;
            }
        }
    }
    return null;
}

/// Find element by fingerprint
pub fn findByFingerprint(tree: *const Tree, fp: Fingerprint) ?*const Element {
    for (tree.elements[0..tree.element_count]) |*elem| {
        if (elem.fingerprint.eql(fp)) {
            return elem;
        }
    }
    return null;
}

/// Assert tree invariants (for testing)
pub fn assertInvariants(tree: *const Tree) void {
    // Element count within bounds
    std.debug.assert(tree.element_count <= constants.MAX_ELEMENTS);

    // Stack depth within bounds
    std.debug.assert(tree.stack_depth <= constants.MAX_DEPTH);

    // All parent references valid
    for (tree.elements[0..tree.element_count]) |elem| {
        if (elem.parent) |p_idx| {
            std.debug.assert(p_idx < tree.element_count);
        }
    }

    // Dirty indices valid
    for (tree.dirty_indices[0..tree.dirty_count]) |idx| {
        std.debug.assert(idx < tree.element_count);
    }
}

// =============================================================================
// Tests
// =============================================================================

test "stats collection" {
    var tree = Tree.init();
    tree.beginFrame();

    _ = tree.pushElement(.{ .role = .button, .name = "Button 1" });
    tree.popElement();

    _ = tree.pushElement(.{ .role = .button, .name = "Button 2" });
    tree.popElement();

    _ = tree.pushElement(.{ .role = .checkbox, .name = "Check", .state = .{ .checked = true } });
    tree.popElement();

    tree.endFrame();

    const stats = getStats(&tree);
    try std.testing.expectEqual(@as(usize, 3), stats.element_count);
    try std.testing.expectEqual(@as(usize, 2), stats.role_counts[@intFromEnum(Role.button)]);
    try std.testing.expectEqual(@as(usize, 1), stats.role_counts[@intFromEnum(Role.checkbox)]);
}

test "validation detects missing name" {
    var tree = Tree.init();
    tree.beginFrame();

    // Interactive element without name
    _ = tree.pushElement(.{ .role = .button });
    tree.popElement();

    tree.endFrame();

    const result = validate(&tree);
    try std.testing.expect(!result.is_valid);
    try std.testing.expect(result.issue_count > 0);
    try std.testing.expectEqual(ValidationIssue.IssueType.missing_name, result.issues[0].issue_type);
}

test "validation passes for valid tree" {
    var tree = Tree.init();
    tree.beginFrame();

    _ = tree.pushElement(.{ .role = .button, .name = "Submit" });
    tree.popElement();

    _ = tree.pushElement(.{ .role = .heading, .name = "Title", .heading_level = 1 });
    tree.popElement();

    tree.endFrame();

    const result = validate(&tree);
    try std.testing.expect(result.is_valid);
    try std.testing.expectEqual(@as(usize, 0), result.issue_count);
}

test "format element" {
    var buf: [256]u8 = undefined;

    const layout_mod = @import("../layout/layout.zig");

    const elem = Element{
        .role = .button,
        .name = "Click me",
        .fingerprint = Fingerprint.INVALID,
        .state = .{},
        .live = .off,
        .layout_id = layout_mod.LayoutId.fromString("test"),
        .description = null,
        .value = null,
        .heading_level = 0,
        .value_min = null,
        .value_max = null,
        .value_now = null,
        .pos_in_set = null,
        .set_size = null,
        .parent = null,
        .first_child = null,
        .last_child = null,
        .next_sibling = null,
        .child_count = 0,
        .labelled_by = null,
        .described_by = null,
        .controls = null,
        .bounds = .{},
    };

    const result = formatElement(&elem, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "button") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Click me") != null);
}

test "format state" {
    var buf: [256]u8 = undefined;

    const state = State{
        .focused = true,
        .checked = true,
        .disabled = false,
    };

    const result = formatState(state, &buf);
    try std.testing.expect(std.mem.indexOf(u8, result, "focused") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "checked") != null);
}

test "find by name" {
    var tree = Tree.init();
    tree.beginFrame();

    _ = tree.pushElement(.{ .role = .button, .name = "First" });
    tree.popElement();

    _ = tree.pushElement(.{ .role = .button, .name = "Second" });
    tree.popElement();

    tree.endFrame();

    const found = findByName(&tree, "Second");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("Second", found.?.name.?);

    const not_found = findByName(&tree, "Third");
    try std.testing.expect(not_found == null);
}

test "count by role" {
    var tree = Tree.init();
    tree.beginFrame();

    _ = tree.pushElement(.{ .role = .button, .name = "B1" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .button, .name = "B2" });
    tree.popElement();
    _ = tree.pushElement(.{ .role = .checkbox, .name = "C1" });
    tree.popElement();

    tree.endFrame();

    try std.testing.expectEqual(@as(usize, 2), countByRole(&tree, .button));
    try std.testing.expectEqual(@as(usize, 1), countByRole(&tree, .checkbox));
    try std.testing.expectEqual(@as(usize, 0), countByRole(&tree, .link));
}

test "assert invariants" {
    var tree = Tree.init();
    tree.beginFrame();

    _ = tree.pushElement(.{ .role = .group, .name = "Parent" });
    _ = tree.pushElement(.{ .role = .button, .name = "Child" });
    tree.popElement();
    tree.popElement();

    tree.endFrame();

    // Should not panic
    assertInvariants(&tree);
}
