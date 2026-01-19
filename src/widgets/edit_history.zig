//! Edit History - Undo/Redo stack for text widgets
//!
//! Fixed-capacity edit stack with coalesced operations.
//! Heap-allocated to avoid stack overflow.
//! Size: MAX_HISTORY_SIZE (128) * ~4KB (Edit with MAX_EDIT_BYTES buffer) = ~512KB
//! Per CLAUDE.md: heap-allocate structs >50KB.

const std = @import("std");

// =============================================================================
// Constants (per CLAUDE.md: put a limit on everything)
// =============================================================================

/// Maximum edits stored in history
pub const MAX_HISTORY_SIZE: u32 = 128;

/// Maximum bytes stored per edit operation
/// Large enough for typical edits, but bounded to prevent memory issues
pub const MAX_EDIT_BYTES: u32 = 4096;

/// Default coalesce window in milliseconds (rapid typing = single undo)
pub const DEFAULT_COALESCE_MS: i64 = 300;

// =============================================================================
// Edit Types
// =============================================================================

/// Edit operation type
pub const EditOp = enum(u8) {
    insert,
    delete,
    /// Compound operation: delete selection then insert new text (single undo step)
    replace,
};

/// Single edit operation (fixed size for pool allocation)
/// Size: ~4KB per edit (dominated by text buffer)
pub const Edit = struct {
    /// Operation type
    op: EditOp = .insert,

    /// Byte offset where edit occurred
    offset: u32 = 0,

    /// Length of text affected
    /// For insert: inserted text length
    /// For delete: deleted text length
    /// For replace: deleted text length
    len: u32 = 0,

    /// Second length field (only used for replace)
    /// For replace: inserted text length
    len2: u32 = 0,

    /// Stored text buffer (fixed size, no allocation)
    /// For insert: stores inserted text (for undo = delete this)
    /// For delete: stores deleted text (for undo = reinsert this)
    /// For replace: stores [deleted_text][inserted_text] concatenated
    text: [MAX_EDIT_BYTES]u8 = undefined,

    /// Actual length of stored text (len for insert/delete, len+len2 for replace)
    text_len: u32 = 0,

    /// Cursor position before edit (for restoring on undo)
    cursor_before: u32 = 0,

    /// Selection anchor before edit (0xFFFFFFFF = null/no selection)
    anchor_before: u32 = 0xFFFFFFFF,

    /// Timestamp for coalescing rapid edits (milliseconds)
    timestamp_ms: i64 = 0,

    const Self = @This();

    /// Get the stored text slice (for insert/delete operations)
    pub fn getText(self: *const Self) []const u8 {
        std.debug.assert(self.op != .replace); // Use getDeletedText/getInsertedText for replace
        std.debug.assert(self.text_len <= MAX_EDIT_BYTES);
        return self.text[0..self.text_len];
    }

    /// Get deleted text (for replace operations)
    pub fn getDeletedText(self: *const Self) []const u8 {
        std.debug.assert(self.op == .replace);
        std.debug.assert(self.len <= self.text_len);
        return self.text[0..self.len];
    }

    /// Get inserted text (for replace operations)
    pub fn getInsertedText(self: *const Self) []const u8 {
        std.debug.assert(self.op == .replace);
        std.debug.assert(self.len + self.len2 <= self.text_len);
        return self.text[self.len .. self.len + self.len2];
    }

    /// Store text into the fixed buffer
    /// Returns true if all text was stored, false if truncated
    pub fn storeText(self: *Self, text: []const u8) bool {
        const copy_len: u32 = @intCast(@min(text.len, MAX_EDIT_BYTES));
        @memcpy(self.text[0..copy_len], text[0..copy_len]);
        self.text_len = copy_len;
        return copy_len == text.len;
    }

    /// Create an insert edit
    pub fn makeInsert(
        offset: u32,
        text: []const u8,
        cursor_before: u32,
        anchor_before: ?u32,
        timestamp: i64,
    ) Self {
        std.debug.assert(text.len <= MAX_EDIT_BYTES);
        var edit = Self{
            .op = .insert,
            .offset = offset,
            .len = @intCast(text.len),
            .len2 = 0,
            .cursor_before = cursor_before,
            .anchor_before = anchor_before orelse 0xFFFFFFFF,
            .timestamp_ms = timestamp,
        };
        _ = edit.storeText(text);
        return edit;
    }

    /// Create a delete edit
    pub fn makeDelete(
        offset: u32,
        deleted_text: []const u8,
        cursor_before: u32,
        anchor_before: ?u32,
        timestamp: i64,
    ) Self {
        std.debug.assert(deleted_text.len <= MAX_EDIT_BYTES);
        var edit = Self{
            .op = .delete,
            .offset = offset,
            .len = @intCast(deleted_text.len),
            .len2 = 0,
            .cursor_before = cursor_before,
            .anchor_before = anchor_before orelse 0xFFFFFFFF,
            .timestamp_ms = timestamp,
        };
        _ = edit.storeText(deleted_text);
        return edit;
    }

    /// Create a replace edit (compound delete + insert as single undo step)
    /// Used when typing over a selection - undo restores the selection in one step
    pub fn makeReplace(
        offset: u32,
        deleted_text: []const u8,
        inserted_text: []const u8,
        cursor_before: u32,
        anchor_before: ?u32,
        timestamp: i64,
    ) ?Self {
        const total_len = deleted_text.len + inserted_text.len;
        // Both texts must fit in buffer
        if (total_len > MAX_EDIT_BYTES) return null;

        std.debug.assert(deleted_text.len <= MAX_EDIT_BYTES);
        std.debug.assert(inserted_text.len <= MAX_EDIT_BYTES);

        var edit = Self{
            .op = .replace,
            .offset = offset,
            .len = @intCast(deleted_text.len),
            .len2 = @intCast(inserted_text.len),
            .cursor_before = cursor_before,
            .anchor_before = anchor_before orelse 0xFFFFFFFF,
            .timestamp_ms = timestamp,
            .text_len = @intCast(total_len),
        };

        // Store deleted text first, then inserted text
        @memcpy(edit.text[0..deleted_text.len], deleted_text);
        @memcpy(edit.text[deleted_text.len .. deleted_text.len + inserted_text.len], inserted_text);

        return edit;
    }

    /// Get anchor as optional (converts sentinel to null)
    pub fn getAnchor(self: *const Self) ?u32 {
        return if (self.anchor_before == 0xFFFFFFFF) null else self.anchor_before;
    }
};

// =============================================================================
// Edit History
// =============================================================================

/// Edit history with fixed-capacity circular buffer
/// Provides undo/redo with automatic coalescing of rapid edits
pub const EditHistory = struct {
    /// Circular buffer of edits (fixed allocation)
    edits: [MAX_HISTORY_SIZE]Edit = undefined,

    /// Number of valid edits in buffer (for redo boundary)
    count: u32 = 0,

    /// Current position in history (next undo index = current - 1)
    current: u32 = 0,

    /// Ring buffer start (for when buffer wraps)
    start: u32 = 0,

    /// Coalesce window in milliseconds
    coalesce_ms: i64 = DEFAULT_COALESCE_MS,

    /// Whether we're in the middle of an undo/redo operation
    /// (prevents recording the undo/redo as a new edit)
    applying_history: bool = false,

    const Self = @This();

    /// Push a new edit onto the history stack
    /// If we're in the middle of the history (after undo), truncates redo history
    pub fn push(self: *Self, edit: Edit) void {
        // Don't record edits while applying undo/redo
        if (self.applying_history) return;

        // Truncate any redo history when new edit comes in
        self.count = self.current;

        // Check if we should coalesce with previous edit
        if (self.current > self.start) {
            const prev_idx = (self.current - 1) % MAX_HISTORY_SIZE;
            const prev = &self.edits[prev_idx];
            if (self.shouldCoalesce(prev, &edit)) {
                self.coalesceEdit(prev, &edit);
                return;
            }
        }

        // Add new edit
        if (self.count < MAX_HISTORY_SIZE) {
            // Buffer not full, just append
            self.edits[self.current % MAX_HISTORY_SIZE] = edit;
            self.current += 1;
            self.count = self.current;
        } else {
            // Buffer full - overwrite oldest entry
            const idx = self.current % MAX_HISTORY_SIZE;
            self.edits[idx] = edit;
            self.current += 1;
            self.count = self.current;
            // Advance start to maintain window
            if (self.current > MAX_HISTORY_SIZE) {
                self.start = self.current - MAX_HISTORY_SIZE;
            }
        }
    }

    /// Undo the most recent edit
    /// Returns the edit to undo, or null if nothing to undo
    /// If the caller fails to apply the edit, call undoUndo() to restore history state
    pub fn undo(self: *Self) ?*const Edit {
        if (!self.canUndo()) return null;

        self.current -= 1;
        const idx = self.current % MAX_HISTORY_SIZE;
        return &self.edits[idx];
    }

    /// Restore history state after a failed undo operation
    /// Call this if applying the undo edit fails (e.g., allocation error)
    pub fn undoUndo(self: *Self) void {
        std.debug.assert(self.current < self.count); // Must have just undone something
        self.current += 1;
    }

    /// Redo the most recently undone edit
    /// Returns the edit to redo, or null if nothing to redo
    /// If the caller fails to apply the edit, call undoRedo() to restore history state
    pub fn redo(self: *Self) ?*const Edit {
        if (!self.canRedo()) return null;

        const idx = self.current % MAX_HISTORY_SIZE;
        self.current += 1;
        return &self.edits[idx];
    }

    /// Restore history state after a failed redo operation
    /// Call this if applying the redo edit fails (e.g., allocation error)
    pub fn undoRedo(self: *Self) void {
        std.debug.assert(self.current > self.start); // Must have just redone something
        self.current -= 1;
    }

    /// Check if undo is available
    pub fn canUndo(self: *const Self) bool {
        return self.current > self.start;
    }

    /// Check if redo is available
    pub fn canRedo(self: *const Self) bool {
        return self.current < self.count;
    }

    /// Clear all history
    pub fn clear(self: *Self) void {
        self.count = 0;
        self.current = 0;
        self.start = 0;
    }

    /// Get number of undoable operations
    pub fn undoCount(self: *const Self) u32 {
        return self.current - self.start;
    }

    /// Get number of redoable operations
    pub fn redoCount(self: *const Self) u32 {
        return self.count - self.current;
    }

    /// Begin applying history (undo/redo) - prevents recording these as new edits
    pub fn beginApply(self: *Self) void {
        std.debug.assert(!self.applying_history);
        self.applying_history = true;
    }

    /// End applying history
    pub fn endApply(self: *Self) void {
        std.debug.assert(self.applying_history);
        self.applying_history = false;
    }

    // =========================================================================
    // Heap Allocation (required - struct is ~512KB)
    // =========================================================================

    /// Create a heap-allocated EditHistory
    /// Returns null on allocation failure
    pub fn create(allocator: std.mem.Allocator) ?*Self {
        const history = allocator.create(Self) catch return null;
        history.* = .{};
        return history;
    }

    /// Destroy a heap-allocated EditHistory
    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    // =========================================================================
    // Coalescing
    // =========================================================================

    /// Check if two edits should be coalesced into one
    fn shouldCoalesce(self: *const Self, prev: *const Edit, new: *const Edit) bool {
        // Only coalesce same operation types (never coalesce replace - it's already compound)
        if (prev.op != new.op) return false;
        if (prev.op == .replace) return false;

        // Check time window
        const time_diff = new.timestamp_ms - prev.timestamp_ms;
        if (time_diff < 0 or time_diff > self.coalesce_ms) return false;

        // For inserts: must be adjacent (cursor immediately after previous insert)
        if (new.op == .insert) {
            const prev_end = prev.offset + prev.len;
            return new.offset == prev_end;
        }

        // For deletes: must be adjacent (backspace coalescing)
        if (new.op == .delete) {
            // Backspace: new delete is just before previous delete
            if (new.offset + new.len == prev.offset) {
                return true;
            }
            // Forward delete: new delete is at same position as previous
            if (new.offset == prev.offset) {
                return true;
            }
        }

        return false;
    }

    /// Coalesce a new edit into an existing one
    fn coalesceEdit(self: *Self, prev: *Edit, new: *const Edit) void {
        _ = self;

        if (new.op == .insert) {
            // Append new text to previous insert
            const new_text = new.getText();
            const available = MAX_EDIT_BYTES - prev.text_len;
            const copy_len = @min(new_text.len, available);

            @memcpy(
                prev.text[prev.text_len .. prev.text_len + @as(u32, @intCast(copy_len))],
                new_text[0..copy_len],
            );
            prev.text_len += @intCast(copy_len);
            prev.len += new.len;
            prev.timestamp_ms = new.timestamp_ms;
        } else if (new.op == .delete) {
            const new_text = new.getText();
            const available = MAX_EDIT_BYTES - prev.text_len;
            const copy_len = @min(new_text.len, available);

            if (new.offset + new.len == prev.offset) {
                // Backspace: prepend new deleted text to previous
                // Shift existing text right
                std.mem.copyBackwards(
                    u8,
                    prev.text[copy_len .. prev.text_len + @as(u32, @intCast(copy_len))],
                    prev.text[0..prev.text_len],
                );
                @memcpy(prev.text[0..copy_len], new_text[0..copy_len]);
                prev.text_len += @intCast(copy_len);
                prev.offset = new.offset;
                prev.len += new.len;
            } else {
                // Forward delete: append new deleted text
                @memcpy(
                    prev.text[prev.text_len .. prev.text_len + @as(u32, @intCast(copy_len))],
                    new_text[0..copy_len],
                );
                prev.text_len += @intCast(copy_len);
                prev.len += new.len;
            }
            prev.timestamp_ms = new.timestamp_ms;
        }
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Edit creation and text storage" {
    const edit = Edit.makeInsert(10, "hello", 5, null, 1000);
    try std.testing.expectEqual(EditOp.insert, edit.op);
    try std.testing.expectEqual(@as(u32, 10), edit.offset);
    try std.testing.expectEqual(@as(u32, 5), edit.len);
    try std.testing.expectEqualStrings("hello", edit.getText());
    try std.testing.expectEqual(@as(u32, 5), edit.cursor_before);
    try std.testing.expectEqual(@as(?u32, null), edit.getAnchor());
}

test "Edit with selection anchor" {
    const edit = Edit.makeDelete(10, "world", 15, 10, 2000);
    try std.testing.expectEqual(@as(?u32, 10), edit.getAnchor());
}

test "Edit history push and undo" {
    var history = EditHistory{};

    // Push some edits
    history.push(Edit.makeInsert(0, "a", 0, null, 100));
    history.push(Edit.makeInsert(1, "b", 1, null, 500)); // Different time, won't coalesce
    history.push(Edit.makeInsert(2, "c", 2, null, 900));

    try std.testing.expectEqual(@as(u32, 3), history.undoCount());
    try std.testing.expectEqual(@as(u32, 0), history.redoCount());

    // Undo one
    const edit1 = history.undo();
    try std.testing.expect(edit1 != null);
    try std.testing.expectEqualStrings("c", edit1.?.getText());
    try std.testing.expectEqual(@as(u32, 2), history.undoCount());
    try std.testing.expectEqual(@as(u32, 1), history.redoCount());

    // Undo another
    const edit2 = history.undo();
    try std.testing.expect(edit2 != null);
    try std.testing.expectEqualStrings("b", edit2.?.getText());
}

test "Edit history redo truncation" {
    var history = EditHistory{};

    history.push(Edit.makeInsert(0, "a", 0, null, 100));
    history.push(Edit.makeInsert(1, "b", 1, null, 500));

    // Undo one
    _ = history.undo();
    try std.testing.expectEqual(@as(u32, 1), history.redoCount());

    // Push new edit - should truncate redo history
    history.push(Edit.makeInsert(1, "x", 1, null, 600));
    try std.testing.expectEqual(@as(u32, 0), history.redoCount());
    try std.testing.expectEqual(@as(u32, 2), history.undoCount());
}

test "Edit coalescing - rapid inserts" {
    var history = EditHistory{};

    // Rapid sequential inserts should coalesce
    history.push(Edit.makeInsert(0, "h", 0, null, 100));
    history.push(Edit.makeInsert(1, "e", 1, null, 150)); // Within 300ms, adjacent
    history.push(Edit.makeInsert(2, "y", 2, null, 200)); // Within 300ms, adjacent

    // Should be coalesced into single edit
    try std.testing.expectEqual(@as(u32, 1), history.undoCount());

    const edit = history.undo();
    try std.testing.expectEqualStrings("hey", edit.?.getText());
}

test "Edit coalescing - timeout" {
    var history = EditHistory{};

    history.push(Edit.makeInsert(0, "a", 0, null, 100));
    history.push(Edit.makeInsert(1, "b", 1, null, 500)); // 400ms later, won't coalesce

    try std.testing.expectEqual(@as(u32, 2), history.undoCount());
}

test "Edit coalescing - backspace" {
    var history = EditHistory{};

    // Backspace deletes: each delete is just before the previous
    history.push(Edit.makeDelete(3, "d", 4, null, 100));
    history.push(Edit.makeDelete(2, "c", 3, null, 150)); // Backspace coalesce
    history.push(Edit.makeDelete(1, "b", 2, null, 200)); // Backspace coalesce

    try std.testing.expectEqual(@as(u32, 1), history.undoCount());

    const edit = history.undo();
    try std.testing.expectEqualStrings("bcd", edit.?.getText());
    try std.testing.expectEqual(@as(u32, 1), edit.?.offset);
}

test "History buffer wrap-around" {
    var history = EditHistory{};

    // Fill beyond capacity
    for (0..MAX_HISTORY_SIZE + 10) |i| {
        history.push(Edit.makeInsert(0, "x", 0, null, @intCast(i * 500)));
    }

    // Should still have MAX_HISTORY_SIZE undos available
    try std.testing.expectEqual(MAX_HISTORY_SIZE, history.undoCount());

    // Can undo all of them
    for (0..MAX_HISTORY_SIZE) |_| {
        try std.testing.expect(history.undo() != null);
    }

    // No more undos
    try std.testing.expect(history.undo() == null);
}

test "Apply history flag" {
    var history = EditHistory{};

    history.push(Edit.makeInsert(0, "a", 0, null, 100));

    // Begin apply - edits should be ignored
    history.beginApply();
    history.push(Edit.makeInsert(1, "b", 1, null, 200));
    history.endApply();

    // Only first edit should be recorded
    try std.testing.expectEqual(@as(u32, 1), history.undoCount());
}

test "Clear history" {
    var history = EditHistory{};

    history.push(Edit.makeInsert(0, "a", 0, null, 100));
    history.push(Edit.makeInsert(1, "b", 1, null, 500));

    history.clear();

    try std.testing.expectEqual(@as(u32, 0), history.undoCount());
    try std.testing.expectEqual(@as(u32, 0), history.redoCount());
}

test "Replace edit creation" {
    const edit = Edit.makeReplace(5, "old", "new text", 8, 5, 1000);
    try std.testing.expect(edit != null);

    const e = edit.?;
    try std.testing.expectEqual(EditOp.replace, e.op);
    try std.testing.expectEqual(@as(u32, 5), e.offset);
    try std.testing.expectEqual(@as(u32, 3), e.len); // deleted len
    try std.testing.expectEqual(@as(u32, 8), e.len2); // inserted len
    try std.testing.expectEqualStrings("old", e.getDeletedText());
    try std.testing.expectEqualStrings("new text", e.getInsertedText());
    try std.testing.expectEqual(@as(u32, 8), e.cursor_before);
    try std.testing.expectEqual(@as(?u32, 5), e.getAnchor());
}

test "Replace edit - buffer overflow returns null" {
    // Create texts that together exceed MAX_EDIT_BYTES
    const big_text = "x" ** (MAX_EDIT_BYTES / 2 + 100);
    const edit = Edit.makeReplace(0, big_text, big_text, 0, null, 1000);
    try std.testing.expect(edit == null);
}

test "Replace edit undo/redo in history" {
    var history = EditHistory{};

    // Simulate: select "world" and type "zig"
    const edit = Edit.makeReplace(6, "world", "zig", 11, 6, 1000);
    try std.testing.expect(edit != null);
    history.push(edit.?);

    try std.testing.expectEqual(@as(u32, 1), history.undoCount());

    // Undo should return the replace edit
    const undone = history.undo();
    try std.testing.expect(undone != null);
    try std.testing.expectEqual(EditOp.replace, undone.?.op);
    try std.testing.expectEqualStrings("world", undone.?.getDeletedText());
    try std.testing.expectEqualStrings("zig", undone.?.getInsertedText());

    // Redo should also work
    const redone = history.redo();
    try std.testing.expect(redone != null);
    try std.testing.expectEqual(EditOp.replace, redone.?.op);
}

test "Replace edits do not coalesce" {
    var history = EditHistory{};

    // Two replace edits in quick succession should NOT coalesce
    const edit1 = Edit.makeReplace(0, "a", "b", 1, 0, 100);
    const edit2 = Edit.makeReplace(0, "b", "c", 1, 0, 150);

    history.push(edit1.?);
    history.push(edit2.?);

    // Should remain as 2 separate edits
    try std.testing.expectEqual(@as(u32, 2), history.undoCount());
}

test "undoUndo restores history state after failed undo" {
    var history = EditHistory{};

    history.push(Edit.makeInsert(0, "hello", 0, null, 100));
    history.push(Edit.makeInsert(5, " world", 5, null, 500));

    try std.testing.expectEqual(@as(u32, 2), history.undoCount());
    try std.testing.expectEqual(@as(u32, 0), history.redoCount());

    // Perform undo
    const edit = history.undo();
    try std.testing.expect(edit != null);
    try std.testing.expectEqual(@as(u32, 1), history.undoCount());
    try std.testing.expectEqual(@as(u32, 1), history.redoCount());

    // Simulate failure - call undoUndo to restore state
    history.undoUndo();

    // State should be restored as if undo never happened
    try std.testing.expectEqual(@as(u32, 2), history.undoCount());
    try std.testing.expectEqual(@as(u32, 0), history.redoCount());
}

test "undoRedo restores history state after failed redo" {
    var history = EditHistory{};

    history.push(Edit.makeInsert(0, "hello", 0, null, 100));

    // Undo first
    _ = history.undo();
    try std.testing.expectEqual(@as(u32, 0), history.undoCount());
    try std.testing.expectEqual(@as(u32, 1), history.redoCount());

    // Perform redo
    const edit = history.redo();
    try std.testing.expect(edit != null);
    try std.testing.expectEqual(@as(u32, 1), history.undoCount());
    try std.testing.expectEqual(@as(u32, 0), history.redoCount());

    // Simulate failure - call undoRedo to restore state
    history.undoRedo();

    // State should be restored as if redo never happened
    try std.testing.expectEqual(@as(u32, 0), history.undoCount());
    try std.testing.expectEqual(@as(u32, 1), history.redoCount());
}
