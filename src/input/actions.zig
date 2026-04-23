//! Action System - Declarative keybindings with context-aware dispatch
//!
//! Actions decouple "what operation" from "what key triggers it":
//! - Define action types (Undo, Save, Delete, etc.)
//! - Bind keystrokes to actions in a keymap
//! - Components register handlers for actions they support
//! - Dispatch matches keystroke → action → handler based on focus context
//!
//! Example:
//! ```zig
//! // Define actions
//! const Undo = struct {};
//! const Save = struct {};
//!
//! // Bind keys (typically at app init)
//! keymap.bind("cmd-z", Undo{}, null);           // Global
//! keymap.bind("cmd-s", Save{}, "Editor");       // Only in Editor context
//!
//! // In component render:
//! dispatch.onAction(Undo, handleUndo);
//! ```

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
        // Single character keys
        if (name.len == 1) {
            const c = name[0];
            if (c >= 'a' and c <= 'z') {
                // Map 'a'-'z' to KeyCode - but they're not contiguous!
                // Need to use the map instead
            }
        }

        // Named keys (including single chars)
        const map = std.StaticStringMap(KeyCode).initComptime(.{
            // Letters
            .{ "a", .a },           .{ "b", .b },         .{ "c", .c },              .{ "d", .d },
            .{ "e", .e },           .{ "f", .f },         .{ "g", .g },              .{ "h", .h },
            .{ "i", .i },           .{ "j", .j },         .{ "k", .k },              .{ "l", .l },
            .{ "m", .m },           .{ "n", .n },         .{ "o", .o },              .{ "p", .p },
            .{ "q", .q },           .{ "r", .r },         .{ "s", .s },              .{ "t", .t },
            .{ "u", .u },           .{ "v", .v },         .{ "w", .w },              .{ "x", .x },
            .{ "y", .y },           .{ "z", .z },
            // Numbers
                    .{ "0", .@"0" },           .{ "1", .@"1" },
            .{ "2", .@"2" },        .{ "3", .@"3" },      .{ "4", .@"4" },           .{ "5", .@"5" },
            .{ "6", .@"6" },        .{ "7", .@"7" },      .{ "8", .@"8" },           .{ "9", .@"9" },
            // Special keys
            .{ "escape", .escape }, .{ "esc", .escape },  .{ "return", .@"return" }, .{ "enter", .@"return" },
            .{ "tab", .tab },       .{ "space", .space }, .{ "backspace", .delete }, .{ "delete", .forward_delete },
            // Arrows
            .{ "up", .up },         .{ "down", .down },   .{ "left", .left },        .{ "right", .right },
            // Navigation
            .{ "home", .home },     .{ "end", .end },     .{ "pageup", .page_up },   .{ "pagedown", .page_down },
            // Function keys
            .{ "f1", .f1 },         .{ "f2", .f2 },       .{ "f3", .f3 },            .{ "f4", .f4 },
            .{ "f5", .f5 },         .{ "f6", .f6 },       .{ "f7", .f7 },            .{ "f8", .f8 },
            .{ "f9", .f9 },         .{ "f10", .f10 },     .{ "f11", .f11 },          .{ "f12", .f12 },
        });

        return map.get(name);
    }
};

// =============================================================================
// Action Type ID
// =============================================================================

/// Type-erased action identifier
pub const ActionTypeId = usize;

/// Get a unique ID for an action type.
/// Uses @typeName address which is unique per type.
pub fn actionTypeId(comptime T: type) ActionTypeId {
    const name_ptr: [*]const u8 = @typeName(T).ptr;
    return @intFromPtr(name_ptr);
}

// =============================================================================
// Key Binding
// =============================================================================

/// A binding from keystroke to action
pub const KeyBinding = struct {
    keystroke: Keystroke,
    action_type: ActionTypeId,
    /// Context required for this binding (null = global)
    context: ?[]const u8,
};

// =============================================================================
// Keymap
// =============================================================================

/// Maps keystrokes to actions, with optional context requirements
pub const Keymap = struct {
    allocator: std.mem.Allocator,
    bindings: std.ArrayListUnmanaged(KeyBinding) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.bindings.deinit(self.allocator);
    }

    /// Bind a keystroke to an action type
    pub fn bind(
        self: *Self,
        comptime Action: type,
        keystroke_str: []const u8,
        context: ?[]const u8,
    ) void {
        const keystroke = Keystroke.parse(keystroke_str) orelse return;
        self.bindings.append(self.allocator, .{
            .keystroke = keystroke,
            .action_type = actionTypeId(Action),
            .context = context,
        }) catch {};
    }

    /// Find a matching binding for a key event given the active contexts
    pub fn match(
        self: *const Self,
        key: KeyCode,
        mods: Modifiers,
        active_contexts: []const []const u8,
    ) ?KeyBinding {
        // Check bindings in reverse order (later bindings override)
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const binding = self.bindings.items[i];

            if (!binding.keystroke.matches(key, mods)) continue;

            // Check context requirement
            if (binding.context) |required_ctx| {
                var found = false;
                for (active_contexts) |ctx| {
                    if (std.mem.eql(u8, ctx, required_ctx)) {
                        found = true;
                        break;
                    }
                }
                if (!found) continue;
            }

            return binding;
        }

        return null;
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
}

test "Keymap binding and matching" {
    const allocator = std.testing.allocator;
    var keymap = Keymap.init(allocator);
    defer keymap.deinit();

    const Undo = struct {};
    const Save = struct {};

    keymap.bind(Undo, "cmd-z", null); // Global
    keymap.bind(Save, "cmd-s", "Editor"); // Editor only

    // cmd-z matches globally
    const match1 = keymap.match(.z, .{ .cmd = true }, &.{});
    try std.testing.expect(match1 != null);
    try std.testing.expectEqual(actionTypeId(Undo), match1.?.action_type);

    // cmd-s only matches with Editor context
    const match2 = keymap.match(.s, .{ .cmd = true }, &.{});
    try std.testing.expect(match2 == null);

    const match3 = keymap.match(.s, .{ .cmd = true }, &.{"Editor"});
    try std.testing.expect(match3 != null);
    try std.testing.expectEqual(actionTypeId(Save), match3.?.action_type);
}
