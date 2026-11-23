const std = @import("std");

const assert = std.debug.assert;

pub const Edit = struct {
    offset: u32,
    deleted_len: u32,
    inserted_len: u32,
    bytes_start: u32,
    cursor_before: u32,
    anchor_before: u32,

    fn size(self: *const Edit) u32 {
        return self.deleted_len + self.inserted_len;
    }

    fn bytesEnd(self: *const Edit) u32 {
        return self.bytes_start + self.size();
    }
};

pub const History = struct {
    edits: []Edit,
    bytes: []u8,
    count: u32,
    applied: u32,
    open: bool,

    pub fn init(edits: []Edit, bytes: []u8) History {
        assert(edits.len > 0);
        assert(bytes.len > 0);
        return .{ .edits = edits, .bytes = bytes, .count = 0, .applied = 0, .open = false };
    }

    pub fn clear(self: *History) void {
        assert(self.applied <= self.count);
        self.count = 0;
        self.applied = 0;
        self.open = false;
    }

    pub fn seal(self: *History) void {
        assert(self.applied <= self.count);
        self.open = false;
    }

    pub fn canUndo(self: *const History) bool {
        assert(self.applied <= self.count);
        return self.applied > 0;
    }

    pub fn canRedo(self: *const History) bool {
        assert(self.applied <= self.count);
        return self.applied < self.count;
    }

    pub fn deletedText(self: *const History, edit: *const Edit) []const u8 {
        assert(edit.bytesEnd() <= self.bytes.len);
        return self.bytes[edit.bytes_start..][0..edit.deleted_len];
    }

    pub fn insertedText(self: *const History, edit: *const Edit) []const u8 {
        assert(edit.bytesEnd() <= self.bytes.len);
        return self.bytes[edit.bytes_start + edit.deleted_len ..][0..edit.inserted_len];
    }

    pub fn record(self: *History, edit: Edit, deleted: []const u8, inserted: []const u8) void {
        assert(edit.deleted_len == deleted.len);
        assert(edit.inserted_len == inserted.len);
        assert(edit.size() > 0);
        self.count = self.applied;
        if (self.open and self.count > 0) {
            if (self.coalesce(&edit, deleted, inserted)) return;
        }
        if (edit.size() > self.bytes.len) {
            self.clear();
            return;
        }
        while (self.count == self.edits.len or self.bytesUsed() + edit.size() > self.bytes.len) {
            self.dropOldest();
        }
        var placed = edit;
        placed.bytes_start = self.bytesUsed();
        @memcpy(self.bytes[placed.bytes_start..][0..deleted.len], deleted);
        @memcpy(self.bytes[placed.bytes_start + edit.deleted_len ..][0..inserted.len], inserted);
        self.edits[self.count] = placed;
        self.count += 1;
        self.applied = self.count;
        self.open = true;
        assert(self.bytesUsed() <= self.bytes.len);
    }

    pub fn undo(self: *History) ?*const Edit {
        if (!self.canUndo()) return null;
        self.open = false;
        self.applied -= 1;
        return &self.edits[self.applied];
    }

    pub fn redo(self: *History) ?*const Edit {
        if (!self.canRedo()) return null;
        self.open = false;
        self.applied += 1;
        return &self.edits[self.applied - 1];
    }

    fn bytesUsed(self: *const History) u32 {
        if (self.count == 0) return 0;
        return self.edits[self.count - 1].bytesEnd();
    }

    fn coalesce(self: *History, edit: *const Edit, deleted: []const u8, inserted: []const u8) bool {
        assert(self.count == self.applied);
        const last = &self.edits[self.count - 1];
        if (self.bytesUsed() + edit.size() > self.bytes.len) return false;
        const typing = last.deleted_len == 0 and deleted.len == 0;
        if (typing and edit.offset == last.offset + last.inserted_len) {
            const previous = self.insertedText(last);
            const word_ended = isSpace(inserted[0]) and !isSpace(previous[previous.len - 1]);
            if (word_ended) return false;
            @memcpy(self.bytes[last.bytesEnd()..][0..inserted.len], inserted);
            last.inserted_len += edit.inserted_len;
            return true;
        }
        const erasing = last.inserted_len == 0 and inserted.len == 0;
        if (erasing and edit.offset + edit.deleted_len == last.offset) {
            const run = self.bytes[last.bytes_start..][0 .. last.deleted_len + deleted.len];
            std.mem.copyBackwards(u8, run[deleted.len..], run[0..last.deleted_len]);
            @memcpy(run[0..deleted.len], deleted);
            last.offset = edit.offset;
            last.deleted_len += edit.deleted_len;
            return true;
        }
        return false;
    }

    fn dropOldest(self: *History) void {
        assert(self.count > 0);
        assert(self.applied == self.count);
        const freed = self.edits[0].size();
        const used = self.bytesUsed();
        std.mem.copyForwards(u8, self.bytes[0 .. used - freed], self.bytes[freed..used]);
        std.mem.copyForwards(Edit, self.edits[0 .. self.count - 1], self.edits[1..self.count]);
        self.count -= 1;
        self.applied = self.count;
        for (self.edits[0..self.count]) |*edit| edit.bytes_start -= freed;
    }
};

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n';
}

fn insertEdit(offset: u32, len: u32) Edit {
    return .{
        .offset = offset,
        .deleted_len = 0,
        .inserted_len = len,
        .bytes_start = 0,
        .cursor_before = offset,
        .anchor_before = offset,
    };
}

test "typing coalesces per word and undo walks back in order" {
    var edits: [4]Edit = undefined;
    var bytes: [16]u8 = undefined;
    var history = History.init(&edits, &bytes);
    for ("ab cd", 0..) |byte, index| {
        history.record(insertEdit(@intCast(index), 1), "", &.{byte});
    }
    try std.testing.expectEqual(@as(u32, 2), history.count);
    const second = history.undo().?;
    try std.testing.expectEqualStrings(" cd", history.insertedText(second));
    const first = history.undo().?;
    try std.testing.expectEqualStrings("ab", history.insertedText(first));
    try std.testing.expect(history.undo() == null);
    try std.testing.expectEqualStrings("ab", history.insertedText(history.redo().?));
    history.record(insertEdit(2, 1), "", "!");
    try std.testing.expect(!history.canRedo());
    try std.testing.expectEqual(@as(u32, 2), history.count);
}

test "backspace runs coalesce at the front" {
    var edits: [4]Edit = undefined;
    var bytes: [16]u8 = undefined;
    var history = History.init(&edits, &bytes);
    for (0..3) |step| {
        const offset: u32 = @intCast(2 - step);
        const deleted = "xyz"[offset..][0..1];
        const edit = Edit{
            .offset = offset,
            .deleted_len = 1,
            .inserted_len = 0,
            .bytes_start = 0,
            .cursor_before = offset + 1,
            .anchor_before = offset + 1,
        };
        history.record(edit, deleted, "");
    }
    try std.testing.expectEqual(@as(u32, 1), history.count);
    const edit = history.undo().?;
    try std.testing.expectEqualStrings("xyz", history.deletedText(edit));
    try std.testing.expectEqual(@as(u32, 0), edit.offset);
}

test "full depth and full bytes drop the oldest edit; oversized edits clear" {
    var edits: [2]Edit = undefined;
    var bytes: [8]u8 = undefined;
    var history = History.init(&edits, &bytes);
    history.record(insertEdit(0, 3), "", "aaa");
    history.seal();
    history.record(insertEdit(3, 3), "", "bbb");
    history.seal();
    history.record(insertEdit(6, 2), "", "cc");
    try std.testing.expectEqual(@as(u32, 2), history.count);
    try std.testing.expectEqualStrings("bbb", history.insertedText(&history.edits[0]));
    try std.testing.expectEqual(@as(u32, 0), history.edits[0].bytes_start);
    history.seal();
    history.record(insertEdit(8, 4), "", "dddd");
    try std.testing.expectEqualStrings("cc", history.insertedText(&history.edits[0]));
    try std.testing.expectEqualStrings("dddd", history.insertedText(&history.edits[1]));
    history.seal();
    history.record(insertEdit(0, 9), "", "eeeeeeeee");
    try std.testing.expect(!history.canUndo());
}
