const std = @import("std");
const element = @import("element.zig");

const assert = std.debug.assert;

pub const Undo = struct {};
pub const Redo = struct {};
pub const Cut = struct {};
pub const Copy = struct {};
pub const Paste = struct {};
pub const SelectAll = struct {};

pub const Unbind = struct {};

pub const TextCommand = enum(u8) {
    move_backward,
    move_forward,
    move_word_backward,
    move_word_forward,
    move_line_start,
    move_line_end,
    move_up,
    move_down,
    move_text_start,
    move_text_end,
    select_backward,
    select_forward,
    select_word_backward,
    select_word_forward,
    select_line_start,
    select_line_end,
    select_up,
    select_down,
    select_text_start,
    select_text_end,
    delete_backward,
    delete_forward,
    delete_word_backward,
    delete_word_forward,
    delete_line_start,
    delete_line_end,
    newline,
    indent,

    pub const count: u32 = std.enums.values(TextCommand).len;
};

pub const Motion = enum(u8) {
    backward,
    forward,
    word_backward,
    word_forward,
    line_start,
    line_end,
    up,
    down,
    text_start,
    text_end,

    pub const count: u32 = std.enums.values(Motion).len;
};

comptime {
    for (std.enums.values(Motion), 0..) |motion, index| {
        const move: TextCommand = @fromBackingInt(@intCast(index));
        const select: TextCommand = @fromBackingInt(@intCast(Motion.count + index));
        assert(std.mem.eql(u8, @tagName(move), "move_" ++ @tagName(motion)));
        assert(std.mem.eql(u8, @tagName(select), "select_" ++ @tagName(motion)));
    }
    assert(@backingInt(TextCommand.delete_backward) == 2 * Motion.count);
}

pub const Move = struct { motion: Motion, extend: bool };

pub fn moveOf(command: TextCommand) ?Move {
    const index: u32 = @backingInt(command);
    if (index < 2 * Motion.count) {
        const extend = index >= Motion.count;
        const motion: Motion = @fromBackingInt(@intCast(index % Motion.count));
        return .{ .motion = motion, .extend = extend };
    }
    return null;
}

pub fn deleteOf(command: TextCommand) ?Motion {
    return switch (command) {
        .delete_backward => .backward,
        .delete_forward => .forward,
        .delete_word_backward => .word_backward,
        .delete_word_forward => .word_forward,
        .delete_line_start => .line_start,
        .delete_line_end => .line_end,
        else => null,
    };
}

pub const text_command = element.action(TextCommand);
pub const undo = element.action(Undo);
pub const redo = element.action(Redo);
pub const cut = element.action(Cut);
pub const copy = element.action(Copy);
pub const paste = element.action(Paste);
pub const select_all = element.action(SelectAll);
pub const unbind = element.action(Unbind);

test "every command is a move, a delete, or an edit, and moves decode both ways" {
    var moves: u32 = 0;
    var deletes: u32 = 0;
    for (std.enums.values(TextCommand)) |command| {
        if (moveOf(command)) |move| {
            const prefix = if (move.extend) "select_" else "move_";
            const name = @tagName(command);
            try std.testing.expect(std.mem.startsWith(u8, name, prefix));
            try std.testing.expectEqualStrings(name[prefix.len..], @tagName(move.motion));
            moves += 1;
        }
        if (deleteOf(command) != null) deletes += 1;
    }
    try std.testing.expectEqual(2 * Motion.count, moves);
    try std.testing.expectEqual(@as(u32, 6), deletes);
    try std.testing.expectEqual(@as(?Move, null), moveOf(.newline));
    try std.testing.expectEqual(Motion.text_end, moveOf(.select_text_end).?.motion);
}
