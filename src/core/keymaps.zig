const std = @import("std");
const element = @import("element.zig");
const keymap = @import("keymap.zig");
const actions = @import("actions.zig");
const input = @import("../input/mod.zig");

const assert = std.debug.assert;

pub const Binding = keymap.Binding;
pub const Convention = keymap.Convention;
const TextCommand = actions.TextCommand;

pub const context_input = element.KeyContext.named("TextInput");
pub const context_area = element.KeyContext.named("TextArea");
pub const context_editor = element.KeyContext.named("CodeEditor");

const Scope = enum { fields, lines, editor };

const Entry = struct { keys: []const u8, command: TextCommand, scope: Scope };

const Standard = struct { keys: []const u8, action: u64 };

const mac_text = [_]Entry{
    .{ .keys = "left", .command = .move_backward, .scope = .fields },
    .{ .keys = "right", .command = .move_forward, .scope = .fields },
    .{ .keys = "shift-left", .command = .select_backward, .scope = .fields },
    .{ .keys = "shift-right", .command = .select_forward, .scope = .fields },
    .{ .keys = "alt-left", .command = .move_word_backward, .scope = .fields },
    .{ .keys = "alt-right", .command = .move_word_forward, .scope = .fields },
    .{ .keys = "alt-shift-left", .command = .select_word_backward, .scope = .fields },
    .{ .keys = "alt-shift-right", .command = .select_word_forward, .scope = .fields },
    .{ .keys = "cmd-left", .command = .move_line_start, .scope = .fields },
    .{ .keys = "cmd-right", .command = .move_line_end, .scope = .fields },
    .{ .keys = "cmd-shift-left", .command = .select_line_start, .scope = .fields },
    .{ .keys = "cmd-shift-right", .command = .select_line_end, .scope = .fields },
    .{ .keys = "home", .command = .move_line_start, .scope = .fields },
    .{ .keys = "end", .command = .move_line_end, .scope = .fields },
    .{ .keys = "shift-home", .command = .select_line_start, .scope = .fields },
    .{ .keys = "shift-end", .command = .select_line_end, .scope = .fields },
    .{ .keys = "ctrl-a", .command = .move_line_start, .scope = .fields },
    .{ .keys = "ctrl-e", .command = .move_line_end, .scope = .fields },
    .{ .keys = "ctrl-shift-a", .command = .select_line_start, .scope = .fields },
    .{ .keys = "ctrl-shift-e", .command = .select_line_end, .scope = .fields },
    .{ .keys = "cmd-home", .command = .move_text_start, .scope = .fields },
    .{ .keys = "cmd-end", .command = .move_text_end, .scope = .fields },
    .{ .keys = "cmd-shift-home", .command = .select_text_start, .scope = .fields },
    .{ .keys = "cmd-shift-end", .command = .select_text_end, .scope = .fields },
    .{ .keys = "backspace", .command = .delete_backward, .scope = .fields },
    .{ .keys = "shift-backspace", .command = .delete_backward, .scope = .fields },
    .{ .keys = "delete", .command = .delete_forward, .scope = .fields },
    .{ .keys = "alt-backspace", .command = .delete_word_backward, .scope = .fields },
    .{ .keys = "alt-delete", .command = .delete_word_forward, .scope = .fields },
    .{ .keys = "cmd-backspace", .command = .delete_line_start, .scope = .fields },
    .{ .keys = "cmd-delete", .command = .delete_line_end, .scope = .fields },
    .{ .keys = "ctrl-k", .command = .delete_line_end, .scope = .fields },
    .{ .keys = "up", .command = .move_up, .scope = .lines },
    .{ .keys = "down", .command = .move_down, .scope = .lines },
    .{ .keys = "shift-up", .command = .select_up, .scope = .lines },
    .{ .keys = "shift-down", .command = .select_down, .scope = .lines },
    .{ .keys = "cmd-up", .command = .move_text_start, .scope = .lines },
    .{ .keys = "cmd-down", .command = .move_text_end, .scope = .lines },
    .{ .keys = "cmd-shift-up", .command = .select_text_start, .scope = .lines },
    .{ .keys = "cmd-shift-down", .command = .select_text_end, .scope = .lines },
    .{ .keys = "enter", .command = .newline, .scope = .lines },
    .{ .keys = "numpadenter", .command = .newline, .scope = .lines },
    .{ .keys = "tab", .command = .indent, .scope = .editor },
};

const pc_text = [_]Entry{
    .{ .keys = "left", .command = .move_backward, .scope = .fields },
    .{ .keys = "right", .command = .move_forward, .scope = .fields },
    .{ .keys = "shift-left", .command = .select_backward, .scope = .fields },
    .{ .keys = "shift-right", .command = .select_forward, .scope = .fields },
    .{ .keys = "ctrl-left", .command = .move_word_backward, .scope = .fields },
    .{ .keys = "ctrl-right", .command = .move_word_forward, .scope = .fields },
    .{ .keys = "ctrl-shift-left", .command = .select_word_backward, .scope = .fields },
    .{ .keys = "ctrl-shift-right", .command = .select_word_forward, .scope = .fields },
    .{ .keys = "home", .command = .move_line_start, .scope = .fields },
    .{ .keys = "end", .command = .move_line_end, .scope = .fields },
    .{ .keys = "shift-home", .command = .select_line_start, .scope = .fields },
    .{ .keys = "shift-end", .command = .select_line_end, .scope = .fields },
    .{ .keys = "ctrl-home", .command = .move_text_start, .scope = .fields },
    .{ .keys = "ctrl-end", .command = .move_text_end, .scope = .fields },
    .{ .keys = "ctrl-shift-home", .command = .select_text_start, .scope = .fields },
    .{ .keys = "ctrl-shift-end", .command = .select_text_end, .scope = .fields },
    .{ .keys = "backspace", .command = .delete_backward, .scope = .fields },
    .{ .keys = "shift-backspace", .command = .delete_backward, .scope = .fields },
    .{ .keys = "delete", .command = .delete_forward, .scope = .fields },
    .{ .keys = "ctrl-backspace", .command = .delete_word_backward, .scope = .fields },
    .{ .keys = "ctrl-delete", .command = .delete_word_forward, .scope = .fields },
    .{ .keys = "ctrl-shift-backspace", .command = .delete_line_start, .scope = .fields },
    .{ .keys = "ctrl-shift-delete", .command = .delete_line_end, .scope = .fields },
    .{ .keys = "up", .command = .move_up, .scope = .lines },
    .{ .keys = "down", .command = .move_down, .scope = .lines },
    .{ .keys = "shift-up", .command = .select_up, .scope = .lines },
    .{ .keys = "shift-down", .command = .select_down, .scope = .lines },
    .{ .keys = "enter", .command = .newline, .scope = .lines },
    .{ .keys = "numpadenter", .command = .newline, .scope = .lines },
    .{ .keys = "tab", .command = .indent, .scope = .editor },
};

const mac_standard = [_]Standard{
    .{ .keys = "cmd-z", .action = actions.undo },
    .{ .keys = "cmd-shift-z", .action = actions.redo },
    .{ .keys = "cmd-x", .action = actions.cut },
    .{ .keys = "cmd-c", .action = actions.copy },
    .{ .keys = "cmd-v", .action = actions.paste },
    .{ .keys = "cmd-a", .action = actions.select_all },
};

const pc_standard = [_]Standard{
    .{ .keys = "ctrl-z", .action = actions.undo },
    .{ .keys = "ctrl-shift-z", .action = actions.redo },
    .{ .keys = "ctrl-y", .action = actions.redo },
    .{ .keys = "ctrl-x", .action = actions.cut },
    .{ .keys = "ctrl-c", .action = actions.copy },
    .{ .keys = "ctrl-v", .action = actions.paste },
    .{ .keys = "ctrl-a", .action = actions.select_all },
};

pub const text_mac: []const Binding = expand(&mac_standard, &mac_text, .mac);
pub const text_pc: []const Binding = expand(&pc_standard, &pc_text, .pc);
pub const text_default: []const Binding = text_mac ++ text_pc;

fn contextsOf(scope: Scope) []const element.KeyContext {
    return switch (scope) {
        .fields => &.{ context_input, context_area, context_editor },
        .lines => &.{ context_area, context_editor },
        .editor => &.{context_editor},
    };
}

fn expandedCount(comptime entries: []const Entry) usize {
    var count: usize = 0;
    for (entries) |entry| count += contextsOf(entry.scope).len;
    return count;
}

fn expand(
    comptime standard: []const Standard,
    comptime entries: []const Entry,
    comptime convention: Convention,
) []const Binding {
    comptime {
        var table: [standard.len + expandedCount(entries)]Binding = undefined;
        var count: usize = 0;
        for (standard) |binding| {
            table[count] = .{
                .keys = binding.keys,
                .action = binding.action,
                .convention = convention,
            };
            count += 1;
        }
        for (entries) |entry| {
            for (contextsOf(entry.scope)) |context| {
                table[count] = .{
                    .keys = entry.keys,
                    .action = actions.text_command,
                    .arg = @backingInt(entry.command),
                    .key_context = context,
                    .convention = convention,
                };
                count += 1;
            }
        }
        assert(count == table.len);
        const final = table;
        return &final;
    }
}

fn expectComplete(comptime convention: Convention) !void {
    const table = comptime keymap.compile(text_default, convention);
    var seen: [actions.TextCommand.count]bool = @splat(false);
    var standard_count: u32 = 0;
    for (table, 0..) |binding, index| {
        try std.testing.expect(binding.action != 0);
        if (binding.action == actions.text_command) {
            try std.testing.expect(binding.arg < actions.TextCommand.count);
            try std.testing.expect(binding.context != 0);
            seen[@intCast(binding.arg)] = true;
        } else {
            try std.testing.expectEqual(@as(u64, 0), binding.context);
            standard_count += 1;
        }
        for (table[0..index]) |earlier| {
            const same_key = std.meta.eql(earlier.keystroke, binding.keystroke);
            try std.testing.expect(!(same_key and earlier.context == binding.context));
        }
    }
    for (seen) |covered| try std.testing.expect(covered);
    try std.testing.expect(standard_count >= 6);
}

test "each platform table covers every command once per keystroke and context" {
    try expectComplete(.mac);
    try expectComplete(.pc);
}

fn find(
    comptime convention: Convention,
    keys: []const u8,
    context: element.KeyContext,
) ?keymap.Match {
    const table = comptime keymap.compile(text_default, convention);
    const keystroke = input.Keystroke.parse(keys).?;
    const key = input.KeyEvent{
        .key = keystroke.key,
        .modifiers = keystroke.modifiers,
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
    const Path = struct {
        context: u64,
        pub fn contains(self: @This(), hash: u64) bool {
            return self.context == hash;
        }
    };
    return keymap.match(table, &key, Path{ .context = context.hash });
}

fn expectCommand(
    comptime convention: Convention,
    keys: []const u8,
    context: element.KeyContext,
    expected: TextCommand,
) !void {
    try std.testing.expectEqual(expected, command(find(convention, keys, context)).?);
}

fn command(match: ?keymap.Match) ?TextCommand {
    const found = match orelse return null;
    if (found.action != actions.text_command) return null;
    return @fromBackingInt(@intCast(found.arg));
}

test "macOS moves by word with Alt and by line with Cmd, and keeps Emacs keys" {
    const input_ctx = context_input;
    try expectCommand(.mac, "alt-left", input_ctx, .move_word_backward);
    try expectCommand(.mac, "cmd-left", input_ctx, .move_line_start);
    try expectCommand(.mac, "ctrl-a", input_ctx, .move_line_start);
    try expectCommand(.mac, "ctrl-e", input_ctx, .move_line_end);
    try expectCommand(.mac, "ctrl-k", input_ctx, .delete_line_end);
    try expectCommand(.mac, "alt-backspace", input_ctx, .delete_word_backward);
    try std.testing.expectEqual(actions.select_all, find(.mac, "cmd-a", input_ctx).?.action);
    try std.testing.expectEqual(@as(?keymap.Match, null), find(.mac, "ctrl-left", input_ctx));
}

test "Linux and Windows move by word with Ctrl and reach the text's ends with Ctrl+Home" {
    const area = context_area;
    try expectCommand(.pc, "ctrl-left", area, .move_word_backward);
    try expectCommand(.pc, "ctrl-shift-right", area, .select_word_forward);
    try expectCommand(.pc, "ctrl-backspace", area, .delete_word_backward);
    try expectCommand(.pc, "ctrl-end", area, .move_text_end);
    try expectCommand(.pc, "home", area, .move_line_start);
    try std.testing.expectEqual(actions.redo, find(.pc, "ctrl-y", area).?.action);
    try std.testing.expectEqual(actions.select_all, find(.pc, "ctrl-a", area).?.action);
    try std.testing.expectEqual(@as(?keymap.Match, null), find(.pc, "alt-left", area));
}

test "Return and Tab are commands only where a field has lines or indents" {
    try std.testing.expectEqual(@as(?keymap.Match, null), find(.pc, "enter", context_input));
    try expectCommand(.pc, "enter", context_area, .newline);
    try std.testing.expectEqual(@as(?keymap.Match, null), find(.mac, "tab", context_area));
    try expectCommand(.mac, "tab", context_editor, .indent);
    try std.testing.expectEqual(@as(?keymap.Match, null), find(.pc, "up", context_input));
}

test "an app binding after the defaults wins, and Unbind lets the key through" {
    const Send = struct {};
    const app_bindings = comptime [_]Binding{
        .{ .keys = "enter", .action = element.action(Send), .key_context = context_area },
        .{ .keys = "secondary-k", .action = element.action(Send) },
        .{ .keys = "home", .action = actions.unbind, .key_context = context_area },
    };
    const table_mac = comptime keymap.compile(text_default ++ &app_bindings, .mac);
    const table_pc = comptime keymap.compile(text_default ++ &app_bindings, .pc);
    const Path = struct {
        pub fn contains(_: @This(), hash: u64) bool {
            return hash == context_area.hash;
        }
    };
    const send = element.action(Send);
    const enter = keyEvent(.@"return", .{});
    try std.testing.expectEqual(send, keymap.match(table_pc, &enter, Path{}).?.action);
    const home = keyEvent(.home, .{});
    try std.testing.expectEqual(@as(?keymap.Match, null), keymap.match(table_pc, &home, Path{}));
    const cmd_k = keyEvent(.k, .{ .cmd = true });
    const ctrl_k = keyEvent(.k, .{ .ctrl = true });
    try std.testing.expectEqual(send, keymap.match(table_mac, &cmd_k, Path{}).?.action);
    try std.testing.expectEqual(send, keymap.match(table_pc, &ctrl_k, Path{}).?.action);
    try std.testing.expectEqual(@as(?keymap.Match, null), keymap.match(table_pc, &cmd_k, Path{}));
}

fn keyEvent(key: input.KeyCode, modifiers: input.Modifiers) input.KeyEvent {
    return .{
        .key = key,
        .modifiers = modifiers,
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
}
