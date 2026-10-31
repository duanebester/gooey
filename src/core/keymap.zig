//! Keymaps and actions (contract §5).
//!
//! An action is a type such as `const Undo = struct {};`, named at runtime by
//! its comptime-hashed id (`ui.action(Undo)`). `Config.keymap` binds key
//! strings such as `"cmd-shift-z"` to actions, optionally only inside a key
//! context (`.key_context = .named("Editor")`). The keymap is parsed at
//! compile time into a static table, so a typo is a compile error and the
//! table claims no storage.
//!
//! On a key press the router walks the focus path (the focused element and
//! its ancestors; with nothing focused, the top-level records). The last
//! binding whose keys match and whose context is on that path names the
//! action, and the first element on the path, innermost first, that lists
//! the action in `Box.actions` handles it. A handled key is consumed: it
//! does not reach `on_key` or the IME.
//!
//! Work per key press: one pass over at most `keymap.len` bindings, each
//! checking at most the path's `box_depth_max + 1` records for its context.

const std = @import("std");
const element = @import("element.zig");
const input = @import("../input/mod.zig");

const assert = std.debug.assert;

pub const KeyContext = element.KeyContext;

/// A keymap entry in `Config.keymap`: `keys` is parsed at compile time.
pub const Binding = struct {
    keys: []const u8,
    action: u64,
    /// Bound only while this context is on the focus path; null is global.
    key_context: ?KeyContext = null,
};

/// A parsed binding. `context` 0 means global.
pub const Compiled = struct {
    keystroke: input.Keystroke,
    action: u64,
    context: u64,
};

/// Parse `bindings` at compile time; a key string that does not parse is a
/// compile error naming it.
pub fn compile(comptime bindings: []const Binding) []const Compiled {
    comptime {
        // `Keystroke.parse` builds its key-name map, a comptime sort.
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

/// The action the last matching binding names, given a predicate telling
/// whether a context hash is on the focus path. Later bindings override
/// earlier ones, as in 0.3.1's `Keymap.match`.
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
    // Goal: 0.3.1's precedence and context rules. Methodology: two bindings
    // for cmd-z, the later one only inside "Editor", queried with and
    // without that context on the path.
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
