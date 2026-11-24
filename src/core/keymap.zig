const std = @import("std");
const builtin = @import("builtin");
const element = @import("element.zig");
const input = @import("../input/mod.zig");

const assert = std.debug.assert;

const unbind = @import("actions.zig").unbind;

pub const KeyContext = element.KeyContext;

pub const Binding = struct {
    keys: []const u8,
    action: u64,
    key_context: ?KeyContext = null,
    arg: u64 = 0,
    convention: ?Convention = null,
};

pub const Convention = enum { mac, pc };

pub const native: Convention = if (builtin.os.tag == .macos) .mac else .pc;

pub const Compiled = struct {
    keystroke: input.Keystroke,
    action: u64,
    arg: u64,
    context: u64,
};

pub const Tables = struct {
    mac: []const Compiled,
    pc: []const Compiled,

    pub fn of(self: *const Tables, convention: Convention) []const Compiled {
        return switch (convention) {
            .mac => self.mac,
            .pc => self.pc,
        };
    }
};

pub const Match = struct { action: u64, arg: u64 };

pub fn compileBoth(comptime bindings: []const Binding) Tables {
    return .{ .mac = compile(bindings, .mac), .pc = compile(bindings, .pc) };
}

pub fn compile(
    comptime bindings: []const Binding,
    comptime convention: Convention,
) []const Compiled {
    comptime {
        @setEvalBranchQuota(20_000 * (bindings.len + 1));
        var table: [countFor(bindings, convention)]Compiled = undefined;
        var count: usize = 0;
        for (bindings) |binding| {
            if (binding.convention) |only| {
                if (only != convention) continue;
            }
            table[count] = compileOne(binding, convention);
            count += 1;
        }
        assert(count == table.len);
        const final = table;
        return &final;
    }
}

fn countFor(comptime bindings: []const Binding, comptime convention: Convention) usize {
    var count: usize = 0;
    for (bindings) |binding| {
        if (binding.convention) |only| {
            if (only != convention) continue;
        }
        count += 1;
    }
    return count;
}

fn compileOne(comptime binding: Binding, comptime convention: Convention) Compiled {
    const label = "gooey.App keymap: \"" ++ binding.keys ++ "\" ";
    if (std.mem.indexOfScalar(u8, binding.keys, ' ') != null) {
        @compileError(label ++ "is a chord; bind a single keystroke");
    }
    const keys = resolveSecondary(binding.keys, convention);
    const keystroke = input.Keystroke.parse(keys) orelse @compileError(label ++
        "is not a keystroke; use optional cmd-, ctrl-, alt-, shift-, secondary- " ++
        "prefixes and a key name, such as \"cmd-shift-z\"");
    if (binding.action == 0) @compileError(label ++
        "has no action; use .action = ui.action(MyAction)");
    return .{
        .keystroke = keystroke,
        .action = binding.action,
        .arg = binding.arg,
        .context = if (binding.key_context) |key_context| key_context.hash else 0,
    };
}

fn resolveSecondary(comptime keys: []const u8, comptime convention: Convention) []const u8 {
    const prefix = "secondary-";
    const index = std.mem.indexOf(u8, keys, prefix) orelse return keys;
    const modifier = switch (convention) {
        .mac => "cmd-",
        .pc => "ctrl-",
    };
    return keys[0..index] ++ modifier ++ keys[index + prefix.len ..];
}

pub fn match(
    table: []const Compiled,
    key: *const input.KeyEvent,
    path_has_context: anytype,
) ?Match {
    var index = table.len;
    while (index > 0) {
        index -= 1;
        const binding = &table[index];
        assert(binding.action != 0);
        if (!binding.keystroke.matches(key.key, key.modifiers)) continue;
        if (binding.context != 0 and !path_has_context.contains(binding.context)) continue;
        if (binding.action == unbind) return null;
        return .{ .action = binding.action, .arg = binding.arg };
    }
    return null;
}

test "the last matching binding wins and contexts gate their bindings" {
    const Undo = struct {};
    const EditorUndo = struct {};
    const table = comptime compile(&.{
        .{ .keys = "cmd-z", .action = element.action(Undo) },
        .{ .keys = "cmd-z", .action = element.action(EditorUndo), .key_context = .named("Editor") },
    }, .mac);
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
    try std.testing.expectEqual(element.action(EditorUndo), match(table, &key, inside).?.action);
    const outside = Path{ .context = KeyContext.named("Other").hash };
    try std.testing.expectEqual(element.action(Undo), match(table, &key, outside).?.action);
    var shifted = key;
    shifted.modifiers.shift = true;
    try std.testing.expectEqual(@as(?Match, null), match(table, &shifted, outside));
}
