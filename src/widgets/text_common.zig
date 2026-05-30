//! Text Common - Shared utilities for text widgets
//!
//! Provides reusable UTF-8 navigation and selection helpers
//! shared between TextInput (single-line) and TextArea (multi-line).

const std = @import("std");

// =============================================================================
// UTF-8 Navigation
// =============================================================================

/// Check if a byte position is on a valid UTF-8 character boundary.
/// A position is valid if it's at the start/end or doesn't point to a continuation byte.
pub fn isCharBoundary(text: []const u8, pos: usize) bool {
    if (pos == 0) return true;
    if (pos >= text.len) return true;
    // Continuation bytes have the pattern 10xxxxxx (0x80-0xBF)
    return (text[pos] & 0xC0) != 0x80;
}

/// Snap a byte position to a valid UTF-8 character boundary.
/// If already valid, returns the same position. Otherwise moves backward
/// to the start of the current character.
pub fn snapToCharBoundary(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    if (pos >= text.len) return text.len;
    if ((text[pos] & 0xC0) != 0x80) return pos;
    return prevCharBoundary(text, pos);
}

/// Find the previous character boundary
pub fn prevCharBoundary(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and (text[i] & 0xC0) == 0x80) {
        i -= 1;
    }
    return i;
}

/// Find the next character boundary
pub fn nextCharBoundary(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var i = pos + 1;
    while (i < text.len and (text[i] & 0xC0) == 0x80) {
        i += 1;
    }
    return i;
}

/// Check if byte at position is whitespace
pub fn isWhitespaceAt(text: []const u8, pos: usize) bool {
    if (pos >= text.len) return true;
    const c = text[pos];
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// Find the previous word boundary
pub fn prevWordBoundary(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = prevCharBoundary(text, pos);
    while (i > 0 and isWhitespaceAt(text, i)) {
        i = prevCharBoundary(text, i);
    }
    while (i > 0 and !isWhitespaceAt(text, prevCharBoundary(text, i))) {
        i = prevCharBoundary(text, i);
    }
    return i;
}

/// Find the next word boundary
pub fn nextWordBoundary(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    var i = pos;
    while (i < text.len and !isWhitespaceAt(text, i)) {
        i = nextCharBoundary(text, i);
    }
    while (i < text.len and isWhitespaceAt(text, i)) {
        i = nextCharBoundary(text, i);
    }
    return i;
}

// =============================================================================
// Selection
// =============================================================================

pub const Selection = struct {
    anchor: ?usize = null,
    cursor: usize = 0,

    pub fn hasSelection(self: Selection) bool {
        return self.anchor != null and self.anchor.? != self.cursor;
    }

    pub fn start(self: Selection) usize {
        return @min(self.anchor orelse self.cursor, self.cursor);
    }

    pub fn end(self: Selection) usize {
        return @max(self.anchor orelse self.cursor, self.cursor);
    }

    pub fn clear(self: *Selection) void {
        self.anchor = null;
    }

    pub fn startSelection(self: *Selection) void {
        if (self.anchor == null) {
            self.anchor = self.cursor;
        }
    }

    pub fn selectAll(self: *Selection, text_len: usize) void {
        self.anchor = 0;
        self.cursor = text_len;
    }
};

// =============================================================================
// Bounds — flat hot-loop rectangle for text-widget hit-testing
// =============================================================================

/// Flat unparameterized rectangle used by `TextInput`, `TextArea`, and
/// `CodeEditorState` for bounds tracking and hit-testing.
///
/// **Why this lives here, not on `core/geometry.Rect/Bounds(T)`.**
/// `core/geometry`'s `Rect(T)` / `Bounds(T)` is a generic value type with a
/// nested `origin: Point(T)` + `size: Size(T)` shape. Text widgets touch
/// `bounds.x` / `bounds.y` / `bounds.width` / `bounds.height` ~150 times
/// across hot rendering and hit-testing loops; rewriting every access to
/// `bounds.origin.x` / `bounds.size.width` would add an indirection that
/// nobody asked for. This flat shape is the one the widgets always wanted —
/// promoting it here (alongside the existing UTF-8 / selection / position
/// helpers shared between the text-widget family) collapses the previous
/// three-way duplicate `Bounds` definition in `text_input_state.zig`,
/// `text_area_state.zig`, and `code_editor_state.zig` into a single tested
/// type without changing memory layout or hot-loop ergonomics.
///
/// **Half-open `[x, x+w)` hit-test convention.** `contains` matches the
/// framework-wide convention used by `core/geometry.Rect.contains` and the
/// layout-engine hit-testing path: a point on the exact right or bottom
/// edge is *outside* the rectangle. This aligns the text-widget family
/// with every other hit-test in the framework. Previously, `text_input`
/// and `text_area` used a closed `[x, x+w]` form (right/bottom edge counted
/// as inside) while `code_editor` already used the half-open form — the
/// closed form was an accidental divergence. The unified half-open
/// semantics are pinned by the test block below; a future refactor that
/// flips the inequality back to `<=` will fail at build time.
pub const Bounds = struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,

    pub fn contains(self: Bounds, px: f32, py: f32) bool {
        return px >= self.x and px < self.x + self.width and
            py >= self.y and py < self.y + self.height;
    }
};

// =============================================================================
// Position (for multi-line)
// =============================================================================

pub const Position = struct {
    row: usize = 0,
    column: usize = 0,

    pub fn eql(self: Position, other: Position) bool {
        return self.row == other.row and self.column == other.column;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "UTF-8 boundary detection" {
    const ascii = "hello";
    try std.testing.expect(isCharBoundary(ascii, 0));
    try std.testing.expect(isCharBoundary(ascii, 1));
    try std.testing.expect(isCharBoundary(ascii, 5));

    const utf8 = "日本語";
    try std.testing.expect(isCharBoundary(utf8, 0));
    try std.testing.expect(!isCharBoundary(utf8, 1));
    try std.testing.expect(!isCharBoundary(utf8, 2));
    try std.testing.expect(isCharBoundary(utf8, 3));
    try std.testing.expect(isCharBoundary(utf8, 6));
    try std.testing.expect(isCharBoundary(utf8, 9));

    try std.testing.expectEqual(@as(usize, 3), nextCharBoundary(utf8, 0));
    try std.testing.expectEqual(@as(usize, 0), prevCharBoundary(utf8, 3));
}

test "Selection operations" {
    var sel = Selection{ .cursor = 5 };
    try std.testing.expect(!sel.hasSelection());

    sel.startSelection();
    try std.testing.expect(!sel.hasSelection());

    sel.cursor = 10;
    try std.testing.expect(sel.hasSelection());
    try std.testing.expectEqual(@as(usize, 5), sel.start());
    try std.testing.expectEqual(@as(usize, 10), sel.end());

    sel.clear();
    try std.testing.expect(!sel.hasSelection());
    try std.testing.expectEqual(@as(usize, 10), sel.cursor);
}

test "Word boundaries" {
    const text = "hello world test";
    try std.testing.expectEqual(@as(usize, 6), nextWordBoundary(text, 0));
    try std.testing.expectEqual(@as(usize, 12), nextWordBoundary(text, 6));
    try std.testing.expectEqual(@as(usize, 6), prevWordBoundary(text, 11));
}

test "Bounds.contains: interior point hits" {
    // Goal: a point strictly inside the rectangle hits, on every axis.
    // Methodology: point at the geometric center of a 10x20 box at (5, 7).
    const b = Bounds{ .x = 5, .y = 7, .width = 10, .height = 20 };
    try std.testing.expect(b.contains(10, 17));
}

test "Bounds.contains: left and top edges are inclusive (hit)" {
    // Goal: pin the half-open `[x, x+w) x [y, y+h)` convention on its closed
    // edges. The left and top edges are *inside* the rectangle.
    // Methodology: point at the exact (x, y) origin and at a left-edge,
    // mid-height point.
    const b = Bounds{ .x = 5, .y = 7, .width = 10, .height = 20 };
    try std.testing.expect(b.contains(5, 7)); // exact origin
    try std.testing.expect(b.contains(5, 17)); // left edge, mid-height
    try std.testing.expect(b.contains(10, 7)); // top edge, mid-width
}

test "Bounds.contains: right and bottom edges are exclusive (miss)" {
    // Goal: pin the half-open `[x, x+w) x [y, y+h)` convention on its open
    // edges. The right and bottom edges are *outside* the rectangle. This
    // matches `core/geometry.Rect.contains` and the framework-wide hit-test
    // convention. A future refactor that flips the inequalities back to
    // `<=` (the pre-PR-8.4-prep behaviour for `text_input` / `text_area`)
    // fails this test.
    // Methodology: points on the exact right and bottom edges of a 10x20
    // box at (5, 7) — i.e. x = 15 and y = 27 — must miss.
    const b = Bounds{ .x = 5, .y = 7, .width = 10, .height = 20 };
    try std.testing.expect(!b.contains(15, 17)); // exact right edge
    try std.testing.expect(!b.contains(10, 27)); // exact bottom edge
    try std.testing.expect(!b.contains(15, 27)); // exact bottom-right corner
}

test "Bounds.contains: points outside in every direction miss" {
    // Goal: complete the cross-product of the hit-test invariant — a point
    // strictly outside the rectangle on any axis misses.
    // Methodology: one point past each of the four edges of a 10x20 box at
    // (5, 7).
    const b = Bounds{ .x = 5, .y = 7, .width = 10, .height = 20 };
    try std.testing.expect(!b.contains(4, 17)); // left of left edge
    try std.testing.expect(!b.contains(16, 17)); // right of right edge
    try std.testing.expect(!b.contains(10, 6)); // above top edge
    try std.testing.expect(!b.contains(10, 28)); // below bottom edge
}

test "Bounds.contains: zero-size rectangle never hits" {
    // Goal: a degenerate zero-width or zero-height rectangle contains no
    // points — a direct consequence of the half-open convention
    // (`x >= 5 and x < 5` is unsatisfiable). Pin this so callers that
    // construct a `Bounds` from layout output before the layout engine
    // has assigned non-zero extents don't accidentally treat their origin
    // as hit-testable.
    // Methodology: zero-width box, zero-height box, fully zero box; the
    // origin point of each must miss.
    const zero_width = Bounds{ .x = 5, .y = 7, .width = 0, .height = 20 };
    const zero_height = Bounds{ .x = 5, .y = 7, .width = 10, .height = 0 };
    const zero = Bounds{ .x = 5, .y = 7, .width = 0, .height = 0 };
    try std.testing.expect(!zero_width.contains(5, 7));
    try std.testing.expect(!zero_height.contains(5, 7));
    try std.testing.expect(!zero.contains(5, 7));
}
