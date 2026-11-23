const std = @import("std");
const element = @import("element.zig");
const input = @import("../input/mod.zig");

const assert = std.debug.assert;

pub const KeyContext = element.KeyContext;

pub const Binding = struct {
    keys: []const u8,
    action: u64,
    key_context: ?KeyContext = null,
};

pub const Compiled = struct {
    keystroke: input.Keystroke,
    action: u64,
    context: u64,
};

pub fn compile(comptime bindings: []const Binding) []const Compiled {
    comptime {
        @setEvalBranchQuota(20_000 * (bindings.len + 1));
        var table: [bindings.len]Compiled = undefined;
        for (bindings, 0..) |binding, index| {
            const keystroke = input.Keystroke.parse(binding.keys) orelse @compileError(
                "gooey.App keymap: \"" ++ binding.keys ++ "\" is not a keystroke; use " ++
                    "optional cmd-, ctrl-, alt-, shift- prefixes and a key name, such as " ++
                    "\"cmd-shift-z\"",
            );
            if (binding.action == 0) @compileError("gooey.App keymap: \"" ++ binding.keys ++
                "\" has no action; use .action = ui.action(MyAction)");
            const context = if (binding.key_context) |key_context| key_context.hash else 0;
            table[index] = .{
                .keystroke = keystroke,
                .action = binding.action,
                .context = context,
            };
        }
        const final = table;
        return &final;
    }
}

pub fn match(
    table: []const Compiled,
    key: *const input.KeyEvent,
    path_has_context: anytype,
) ?u64 {
    var index = table.len;
    while (index > 0) {
        index -= 1;
        const binding = &table[index];
        assert(binding.action != 0);
        if (!binding.keystroke.matches(key.key, key.modifiers)) continue;
        if (binding.context != 0 and !path_has_context.contains(binding.context)) continue;
        return binding.action;
    }
    return null;
}

test "the last matching binding wins and contexts gate their bindings" {
    const Undo = struct {};
    const EditorUndo = struct {};
    const table = comptime compile(&.{
        .{ .keys = "cmd-z", .action = element.action(Undo) },
        .{ .keys = "cmd-z", .action = element.action(EditorUndo), .key_context = .named("Editor") },
    });
    const Path = struct {
        context: u64,
        fn contains(self: @This(), hash: u64) bool {
            return self.context == hash;
        }
    };
    const key = input.KeyEvent{
        .key = .z,
        .modifiers = .{ .cmd = true },
        .characters = null,
        .characters_ignoring_modifiers = null,
        .is_repeat = false,
    };
    const inside = Path{ .context = KeyContext.named("Editor").hash };
    try std.testing.expectEqual(element.action(EditorUndo), match(table, &key, inside).?);
    const outside = Path{ .context = KeyContext.named("Other").hash };
    try std.testing.expectEqual(element.action(Undo), match(table, &key, outside).?);
    var shifted = key;
    shifted.modifiers.shift = true;
    try std.testing.expectEqual(@as(?u64, null), match(table, &shifted, outside));
}
