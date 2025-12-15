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
