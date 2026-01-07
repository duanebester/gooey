//! Semantic types for accessible elements.
//!
//! Based on WAI-ARIA with mappings to platform equivalents.
//! Roles are exhaustive - no "custom" role to prevent misuse.

const std = @import("std");

/// Semantic role - what IS this element?
/// Deliberately limited set covering Gooey's component library.
pub const Role = enum(u8) {
    // Atomic widgets
    button = 0,
    checkbox = 1,
    radio = 2,
    switch_ = 3, // toggle switch
    link = 4,

    // Text input
    textbox = 5, // single-line
    textarea = 6, // multi-line
    searchbox = 7,
    spinbutton = 8, // numeric input

    // Selection
    combobox = 10, // dropdown
    listbox = 11,
    option = 12,
    menu = 13,
    menuitem = 14,
    menubar = 15,

    // Navigation
    tab = 20,
    tablist = 21,
    tabpanel = 22,

    // Disclosure
    tree = 25,
    treeitem = 26,

    // Sliders
    slider = 30,
    scrollbar = 31,

    // Structure
    group = 40, // generic grouping
    region = 41, // landmark
    dialog = 42,
    alertdialog = 43,
    toolbar = 44,
    tooltip = 45,

    // Status
    alert = 50, // important, time-sensitive
    status = 51, // advisory
    progressbar = 52,

    // Document
    heading = 60,
    paragraph = 61,
    list = 62,
    listitem = 63,
    img = 64,
    separator = 65,

    // Special
    presentation = 254, // explicitly NOT accessible
    none = 255, // inherit from context

    /// Convert to macOS NSAccessibility role identifier
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
            .option => "AXStaticText",
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

    /// Convert to AT-SPI2 role constant (Linux)
    pub fn toAtspiRole(self: Role) u32 {
        return switch (self) {
            .button => 25, // ATSPI_ROLE_PUSH_BUTTON
            .checkbox => 8, // ATSPI_ROLE_CHECK_BOX
            .radio => 49, // ATSPI_ROLE_RADIO_BUTTON
            .switch_ => 8, // ATSPI_ROLE_CHECK_BOX
            .link => 36, // ATSPI_ROLE_LINK
            .textbox => 60, // ATSPI_ROLE_TEXT
            .textarea => 60, // ATSPI_ROLE_TEXT
            .searchbox => 60, // ATSPI_ROLE_TEXT
            .spinbutton => 55, // ATSPI_ROLE_SPIN_BUTTON
            .combobox => 9, // ATSPI_ROLE_COMBO_BOX
            .listbox => 35, // ATSPI_ROLE_LIST
            .option => 36, // ATSPI_ROLE_LIST_ITEM
            .menu => 38, // ATSPI_ROLE_MENU
            .menuitem => 40, // ATSPI_ROLE_MENU_ITEM
            .menubar => 39, // ATSPI_ROLE_MENU_BAR
            .tab => 47, // ATSPI_ROLE_PAGE_TAB
            .tablist => 48, // ATSPI_ROLE_PAGE_TAB_LIST
            .tabpanel => 68, // ATSPI_ROLE_PANEL
            .tree => 64, // ATSPI_ROLE_TREE
            .treeitem => 65, // ATSPI_ROLE_TREE_ITEM
            .slider => 52, // ATSPI_ROLE_SLIDER
            .scrollbar => 51, // ATSPI_ROLE_SCROLL_BAR
            .group => 68, // ATSPI_ROLE_PANEL
            .region => 68, // ATSPI_ROLE_PANEL
            .dialog => 14, // ATSPI_ROLE_DIALOG
            .alertdialog => 14, // ATSPI_ROLE_DIALOG
            .toolbar => 62, // ATSPI_ROLE_TOOL_BAR
            .tooltip => 63, // ATSPI_ROLE_TOOL_TIP
            .alert => 2, // ATSPI_ROLE_ALERT
            .status => 56, // ATSPI_ROLE_STATUS_BAR
            .progressbar => 46, // ATSPI_ROLE_PROGRESS_BAR
            .heading => 23, // ATSPI_ROLE_HEADING
            .paragraph => 45, // ATSPI_ROLE_PARAGRAPH
            .list => 35, // ATSPI_ROLE_LIST
            .listitem => 36, // ATSPI_ROLE_LIST_ITEM
            .img => 26, // ATSPI_ROLE_IMAGE
            .separator => 53, // ATSPI_ROLE_SEPARATOR
            .presentation, .none => 68, // ATSPI_ROLE_PANEL
        };
    }

    /// Convert to ARIA role string (Web)
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

    /// Returns true if this role typically accepts keyboard focus
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

/// Element state flags - packed for cache efficiency.
/// All fields default false (zero-initialized).
pub const State = packed struct(u16) {
    focused: bool = false, // has keyboard focus
    selected: bool = false, // selected in a collection
    checked: bool = false, // checkbox/radio/switch is on
    pressed: bool = false, // toggle button is pressed
    expanded: bool = false, // disclosure is open
    disabled: bool = false, // non-interactive
    readonly: bool = false, // value cannot be changed
    required: bool = false, // form field is required
    invalid: bool = false, // validation failed
    busy: bool = false, // async operation in progress
    hidden: bool = false, // not visible (skip in a11y tree)
    _reserved: u5 = 0,

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

/// Live region politeness for announcements
pub const Live = enum(u2) {
    off = 0, // no announcements
    polite = 1, // announce when idle
    assertive = 2, // interrupt immediately

    pub fn toAriaLive(self: Live) ?[]const u8 {
        return switch (self) {
            .off => null,
            .polite => "polite",
            .assertive => "assertive",
        };
    }
};

/// Heading level (1-6, 0 = not a heading)
pub const HeadingLevel = u3;

// Compile-time assertions per CLAUDE.md
comptime {
    // State must fit in 16 bits
    std.debug.assert(@sizeOf(State) == 2);
    std.debug.assert(@bitSizeOf(State) == 16);

    // Role must fit in a byte
    std.debug.assert(@sizeOf(Role) == 1);

    // Live must be minimal
    std.debug.assert(@sizeOf(Live) == 1);
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

test "role conversions" {
    try std.testing.expectEqualStrings("AXButton", Role.button.toNSRole());
    try std.testing.expectEqualStrings("button", Role.button.toAriaRole());
    try std.testing.expectEqual(@as(u32, 25), Role.button.toAtspiRole());
}

test "live aria conversion" {
    try std.testing.expectEqual(@as(?[]const u8, null), Live.off.toAriaLive());
    try std.testing.expectEqualStrings("polite", Live.polite.toAriaLive().?);
    try std.testing.expectEqualStrings("assertive", Live.assertive.toAriaLive().?);
}
