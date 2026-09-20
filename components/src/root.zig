//! Gooey Components
//!
//! High-level components built exclusively on Gooey's public API.

const std = @import("std");

pub const Button = @import("button.zig").Button;
pub const Checkbox = @import("checkbox.zig").Checkbox;
pub const TextInput = @import("text_input.zig").TextInput;
pub const TextArea = @import("text_area.zig").TextArea;
pub const CodeEditor = @import("code_editor.zig").CodeEditor;
pub const ProgressBar = @import("progress_bar.zig").ProgressBar;
pub const RadioGroup = @import("radio_group.zig").RadioGroup;
pub const RadioButton = @import("radio_group.zig").RadioButton;
pub const Tab = @import("tabs.zig").Tab;
pub const TabBar = @import("tabs.zig").TabBar;
pub const Svg = @import("svg.zig").Svg;
pub const Icons = @import("svg.zig").Icons;
pub const Lucide = @import("svg.zig").Lucide;
pub const Select = @import("select.zig").Select;
pub const Image = @import("image.zig").Image;
pub const AspectRatio = @import("image.zig").AspectRatio;
pub const Tooltip = @import("tooltip.zig").Tooltip;
pub const Modal = @import("modal.zig").Modal;
pub const ContextMenu = @import("context_menu.zig").ContextMenu;
pub const MenuItem = @import("context_menu.zig").MenuItem;
pub const ValidatedTextInput = @import("validated_text_input.zig").ValidatedTextInput;

test {
    std.testing.refAllDecls(@This());
}

test "public component surface compiles" {
    comptime {
        _ = Button;
        _ = Checkbox;
        _ = TextInput;
        _ = TextArea;
        _ = CodeEditor;
        _ = ProgressBar;
        _ = RadioGroup;
        _ = RadioButton;
        _ = Tab;
        _ = TabBar;
        _ = Svg;
        _ = Icons;
        _ = Lucide;
        _ = Select;
        _ = Image;
        _ = AspectRatio;
        _ = Tooltip;
        _ = Modal;
        _ = ContextMenu;
        _ = MenuItem;
        _ = ValidatedTextInput;
    }
}

test "documented component literals compile" {
    const button = Button{ .label = "Save" };
    const checkbox = Checkbox{ .selected = false, .label = "Remember me" };
    const text_input = TextInput{ .id = "email", .placeholder = "Email" };

    std.debug.assert(button.label.len > 0);
    std.debug.assert(text_input.id.len > 0);
    _ = checkbox;
    _ = Image{ .src = "logo.png" };
    _ = Svg{ .path = "M0 0" };
}
