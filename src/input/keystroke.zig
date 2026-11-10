//! Keystrokes: "cmd-z" or "ctrl-shift-s" parsed into a key and modifiers,
//! for the core's keymaps (`core/keymap.zig`), which parse at compile time.

const std = @import("std");
const input_mod = @import("events.zig");

const KeyCode = input_mod.KeyCode;
const Modifiers = input_mod.Modifiers;

// =============================================================================
// Keystroke
// =============================================================================

/// A parsed keystroke like "cmd-z" or "ctrl-shift-s"
pub const Keystroke = struct {
    key: KeyCode,
    modifiers: Modifiers,

    const Self = @This();

    /// Parse a keystroke string like "cmd-z", "ctrl-shift-s", "escape"
    pub fn parse(str: []const u8) ?Self {
        var mods = Modifiers{};
        var remaining = str;

        // Parse modifier prefixes
        while (true) {
            if (startsWith(remaining, "cmd-") or startsWith(remaining, "super-")) {
                mods.cmd = true;
                remaining = remaining[4..];
            } else if (startsWith(remaining, "ctrl-")) {
                mods.ctrl = true;
                remaining = remaining[5..];
            } else if (startsWith(remaining, "alt-") or startsWith(remaining, "opt-")) {
                mods.alt = true;
                remaining = remaining[4..];
            } else if (startsWith(remaining, "shift-")) {
                mods.shift = true;
                remaining = remaining[6..];
            } else {
                break;
            }
        }

        // Parse key name
        const key = parseKeyName(remaining) orelse return null;

        return .{ .key = key, .modifiers = mods };
    }

    /// Check if this keystroke matches a key event
    pub fn matches(self: Self, key: KeyCode, mods: Modifiers) bool {
        return self.key == key and
            self.modifiers.cmd == mods.cmd and
            self.modifiers.ctrl == mods.ctrl and
            self.modifiers.alt == mods.alt and
            self.modifiers.shift == mods.shift;
    }

    fn startsWith(haystack: []const u8, needle: []const u8) bool {
        if (haystack.len < needle.len) return false;
        return std.mem.eql(u8, haystack[0..needle.len], needle);
    }

    fn parseKeyName(name: []const u8) ?KeyCode {
        // Every single-character tag (a to z, 0 to 9) is spelled as its key.
        if (name.len == 1) return std.meta.stringToEnum(KeyCode, name);

        // Named keys and their aliases.
        const map = std.StaticStringMap(KeyCode).initComptime(.{
            // Special keys
            .{ "escape", .escape },    .{ "esc", .escape },
            .{ "return", .@"return" }, .{ "enter", .@"return" },
            .{ "tab", .tab },          .{ "space", .space },
            .{ "backspace", .delete }, .{ "delete", .forward_delete },
            // Arrows
            .{ "up", .up },            .{ "down", .down },
            .{ "left", .left },        .{ "right", .right },
            // Navigation
            .{ "home", .home },        .{ "end", .end },
            .{ "pageup", .page_up },   .{ "pagedown", .page_down },
            // Function keys
            .{ "f1", .f1 },            .{ "f2", .f2 },
            .{ "f3", .f3 },            .{ "f4", .f4 },
            .{ "f5", .f5 },            .{ "f6", .f6 },
            .{ "f7", .f7 },            .{ "f8", .f8 },
            .{ "f9", .f9 },            .{ "f10", .f10 },
            .{ "f11", .f11 },          .{ "f12", .f12 },
        });

        return map.get(name);
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Keystroke parsing" {
    const ks1 = Keystroke.parse("cmd-z").?;
    try std.testing.expectEqual(KeyCode.z, ks1.key);
    try std.testing.expect(ks1.modifiers.cmd);
    try std.testing.expect(!ks1.modifiers.shift);

    const ks2 = Keystroke.parse("ctrl-shift-s").?;
    try std.testing.expectEqual(KeyCode.s, ks2.key);
    try std.testing.expect(ks2.modifiers.ctrl);
    try std.testing.expect(ks2.modifiers.shift);

    const ks3 = Keystroke.parse("escape").?;
    try std.testing.expectEqual(KeyCode.escape, ks3.key);

    // Digits and letters resolve by tag name; aliases resolve by table;
    // tag names that are not key names (`forward_delete`) stay rejected.
    try std.testing.expectEqual(KeyCode.@"5", Keystroke.parse("alt-5").?.key);
    try std.testing.expectEqual(KeyCode.@"return", Keystroke.parse("enter").?.key);
    try std.testing.expectEqual(KeyCode.page_down, Keystroke.parse("pagedown").?.key);
    try std.testing.expectEqual(KeyCode.f12, Keystroke.parse("f12").?.key);
    try std.testing.expect(Keystroke.parse("forward_delete") == null);
    try std.testing.expect(Keystroke.parse("cmd-ab") == null);
}
