const std = @import("std");

pub const Role = enum(u8) {
    button = 0,
    checkbox = 1,
    radio = 2,
    switch_ = 3,
    link = 4,

    textbox = 5,
    textarea = 6,
    searchbox = 7,
    spinbutton = 8,

    combobox = 10,
    listbox = 11,
    option = 12,
    menu = 13,
    menuitem = 14,
    menubar = 15,

    tab = 20,
    tablist = 21,
    tabpanel = 22,

    tree = 25,
    treeitem = 26,

    slider = 30,
    scrollbar = 31,

    group = 40,
    region = 41,
    dialog = 42,
    alertdialog = 43,
    toolbar = 44,
    tooltip = 45,

    alert = 50,
    status = 51,
    progressbar = 52,

    heading = 60,
    paragraph = 61,
    list = 62,
    listitem = 63,
    img = 64,
    separator = 65,

    presentation = 254,
    none = 255,

    pub fn toNSRole(self: Role) []const u8 {
        return switch (self) {
            .button => "AXButton",
            .checkbox => "AXCheckBox",
            .radio => "AXRadioButton",
            .switch_ => "AXCheckBox",
            .link => "AXLink",
            .textbox => "AXTextField",
            .textarea => "AXTextArea",
            .searchbox => "AXSearchField",
            .spinbutton => "AXIncrementor",
            .combobox => "AXComboBox",
            .listbox => "AXList",
            .option => "AXRadioButton",
            .menu => "AXMenu",
            .menuitem => "AXMenuItem",
            .menubar => "AXMenuBar",
            .tab => "AXRadioButton",
            .tablist => "AXTabGroup",
            .tabpanel => "AXGroup",
            .tree => "AXOutline",
            .treeitem => "AXRow",
            .slider => "AXSlider",
            .scrollbar => "AXScrollBar",
            .group => "AXGroup",
            .region => "AXGroup",
            .dialog => "AXDialog",
            .alertdialog => "AXDialog",
            .toolbar => "AXToolbar",
            .tooltip => "AXHelpTag",
            .alert => "AXGroup",
            .status => "AXGroup",
            .progressbar => "AXProgressIndicator",
            .heading => "AXHeading",
            .paragraph => "AXGroup",
            .list => "AXList",
            .listitem => "AXGroup",
            .img => "AXImage",
            .separator => "AXSplitter",
            .presentation, .none => "AXGroup",
        };
    }

    pub fn toAtspiRole(self: Role) u32 {
        return switch (self) {
            .button => 25,
            .checkbox => 8,
            .radio => 49,
            .switch_ => 8,
            .link => 36,
            .textbox => 60,
            .textarea => 60,
            .searchbox => 60,
            .spinbutton => 55,
            .combobox => 9,
            .listbox => 35,
            .option => 36,
            .menu => 38,
            .menuitem => 40,
            .menubar => 39,
            .tab => 47,
            .tablist => 48,
            .tabpanel => 68,
            .tree => 64,
            .treeitem => 65,
            .slider => 52,
            .scrollbar => 51,
            .group => 68,
            .region => 68,
            .dialog => 14,
            .alertdialog => 14,
            .toolbar => 62,
            .tooltip => 63,
            .alert => 2,
            .status => 56,
            .progressbar => 46,
            .heading => 23,
            .paragraph => 45,
            .list => 35,
            .listitem => 36,
            .img => 26,
            .separator => 53,
            .presentation, .none => 68,
        };
    }

    pub fn toUiaControlType(self: Role) i32 {
        return switch (self) {
            .button => 50000,
            .checkbox => 50002,
            .radio => 50013,
            .switch_ => 50000,
            .link => 50005,
            .textbox => 50004,
            .textarea => 50004,
            .searchbox => 50004,
            .spinbutton => 50016,
            .combobox => 50003,
            .listbox => 50008,
            .option => 50007,
            .menu => 50009,
            .menuitem => 50011,
            .menubar => 50010,
            .tab => 50019,
            .tablist => 50018,
            .tabpanel => 50033,
            .tree => 50023,
            .treeitem => 50024,
            .slider => 50015,
            .scrollbar => 50014,
            .group => 50026,
            .region => 50026,
            .dialog => 50033,
            .alertdialog => 50033,
            .toolbar => 50021,
            .tooltip => 50022,
            .alert => 50020,
            .status => 50017,
            .progressbar => 50012,
            .heading => 50020,
            .paragraph => 50026,
            .list => 50008,
            .listitem => 50007,
            .img => 50006,
            .separator => 50038,
            .presentation, .none => 50026,
        };
    }

    pub fn toAriaRole(self: Role) []const u8 {
        return switch (self) {
            .button => "button",
            .checkbox => "checkbox",
            .radio => "radio",
            .switch_ => "switch",
            .link => "link",
            .textbox => "textbox",
            .textarea => "textbox",
            .searchbox => "searchbox",
            .spinbutton => "spinbutton",
            .combobox => "combobox",
            .listbox => "listbox",
            .option => "option",
            .menu => "menu",
            .menuitem => "menuitem",
            .menubar => "menubar",
            .tab => "tab",
            .tablist => "tablist",
            .tabpanel => "tabpanel",
            .tree => "tree",
            .treeitem => "treeitem",
            .slider => "slider",
            .scrollbar => "scrollbar",
            .group => "group",
            .region => "region",
            .dialog => "dialog",
            .alertdialog => "alertdialog",
            .toolbar => "toolbar",
            .tooltip => "tooltip",
            .alert => "alert",
            .status => "status",
            .progressbar => "progressbar",
            .heading => "heading",
            .paragraph => "paragraph",
            .list => "list",
            .listitem => "listitem",
            .img => "img",
            .separator => "separator",
            .presentation => "presentation",
            .none => "none",
        };
    }

    pub fn isFocusableByDefault(self: Role) bool {
        return switch (self) {
            .button,
            .checkbox,
            .radio,
            .switch_,
            .link,
            .textbox,
            .textarea,
            .searchbox,
            .spinbutton,
            .combobox,
            .listbox,
            .option,
            .menuitem,
            .tab,
            .treeitem,
            .slider,
            .scrollbar,
            => true,
            else => false,
        };
    }
};

pub const State = packed struct(u16) {
    focused: bool = false,
    selected: bool = false,
    checked: bool = false,
    pressed: bool = false,
    expanded: bool = false,
    disabled: bool = false,
    readonly: bool = false,
    required: bool = false,
    invalid: bool = false,
    busy: bool = false,
    hidden: bool = false,
    has_popup: bool = false,
    _reserved: u4 = 0,

    pub fn eql(self: State, other: State) bool {
        return @as(u16, @bitCast(self)) == @as(u16, @bitCast(other));
    }

    pub fn toU16(self: State) u16 {
        return @bitCast(self);
    }

    pub fn fromU16(value: u16) State {
        return @bitCast(value);
    }
};

pub const Live = enum(u2) {
    off = 0,
    polite = 1,
    assertive = 2,

    pub fn toAriaLive(self: Live) ?[]const u8 {
        return switch (self) {
            .off => null,
            .polite => "polite",
            .assertive => "assertive",
        };
    }
};

pub const Orientation = enum(u1) {
    horizontal = 0,
    vertical = 1,
};

pub const HeadingLevel = enum(u3) {
    none = 0,
    h1 = 1,
    h2 = 2,
    h3 = 3,
    h4 = 4,
    h5 = 5,
    h6 = 6,

    pub fn toAriaLevel(self: HeadingLevel) ?u8 {
        return switch (self) {
            .none => null,
            .h1 => 1,
            .h2 => 2,
            .h3 => 3,
            .h4 => 4,
            .h5 => 5,
            .h6 => 6,
        };
    }

    pub fn fromInt(level: u8) HeadingLevel {
        return switch (level) {
            1 => .h1,
            2 => .h2,
            3 => .h3,
            4 => .h4,
            5 => .h5,
            6 => .h6,
            else => .none,
        };
    }

    pub fn isHeading(self: HeadingLevel) bool {
        return self != .none;
    }
};

comptime {
    std.debug.assert(@sizeOf(State) == 2);
    std.debug.assert(@bitSizeOf(State) == 16);

    std.debug.assert(@sizeOf(Role) == 1);

    std.debug.assert(@sizeOf(Live) == 1);

    std.debug.assert(@sizeOf(HeadingLevel) == 1);
}

test "heading level validation" {
    try std.testing.expectEqual(@as(?u8, 1), HeadingLevel.h1.toAriaLevel());
    try std.testing.expectEqual(@as(?u8, 6), HeadingLevel.h6.toAriaLevel());
    try std.testing.expectEqual(@as(?u8, null), HeadingLevel.none.toAriaLevel());

    try std.testing.expectEqual(HeadingLevel.h1, HeadingLevel.fromInt(1));
    try std.testing.expectEqual(HeadingLevel.none, HeadingLevel.fromInt(0));
    try std.testing.expectEqual(HeadingLevel.none, HeadingLevel.fromInt(7));
    try std.testing.expectEqual(HeadingLevel.none, HeadingLevel.fromInt(255));

    try std.testing.expect(HeadingLevel.h1.isHeading());
    try std.testing.expect(!HeadingLevel.none.isHeading());
}

test "state equality" {
    const s1 = State{ .focused = true, .disabled = false };
    const s2 = State{ .focused = true, .disabled = false };
    const s3 = State{ .focused = false, .disabled = true };

    try std.testing.expect(s1.eql(s2));
    try std.testing.expect(!s1.eql(s3));
}

test "state bitcast roundtrip" {
    const s1 = State{ .focused = true, .checked = true, .expanded = true };
    const bits = s1.toU16();
    const s2 = State.fromU16(bits);

    try std.testing.expect(s1.eql(s2));
    try std.testing.expect(s2.focused);
    try std.testing.expect(s2.checked);
    try std.testing.expect(s2.expanded);
    try std.testing.expect(!s2.disabled);
}

test "has_popup state field" {
    const s1 = State{};
    try std.testing.expect(!s1.has_popup);

    const s2 = State{ .has_popup = true };
    try std.testing.expect(s2.has_popup);

    const s3 = State{ .expanded = true, .has_popup = true };
    try std.testing.expect(s3.expanded);
    try std.testing.expect(s3.has_popup);
    try std.testing.expect(!s3.disabled);

    const bits = s3.toU16();
    const s4 = State.fromU16(bits);
    try std.testing.expect(s3.eql(s4));
    try std.testing.expect(s4.has_popup);
    try std.testing.expect(s4.expanded);

    const s5 = State{ .has_popup = true };
    const s6 = State{ .has_popup = false };
    try std.testing.expect(!s5.eql(s6));
}

test "role conversions" {
    try std.testing.expectEqualStrings("AXButton", Role.button.toNSRole());
    try std.testing.expectEqualStrings("button", Role.button.toAriaRole());
    try std.testing.expectEqual(@as(u32, 25), Role.button.toAtspiRole());
    try std.testing.expectEqual(@as(i32, 50000), Role.button.toUiaControlType());
    try std.testing.expectEqual(@as(i32, 50004), Role.textarea.toUiaControlType());
}

test "live aria conversion" {
    try std.testing.expectEqual(@as(?[]const u8, null), Live.off.toAriaLive());
    try std.testing.expectEqualStrings("polite", Live.polite.toAriaLive().?);
    try std.testing.expectEqualStrings("assertive", Live.assertive.toAriaLive().?);
}
