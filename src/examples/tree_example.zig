//! TreeList Example - File Browser Style Tree View
//!
//! This example demonstrates how to use TreeList for efficient rendering
//! of hierarchical data. Only visible items are rendered, with support
//! for expand/collapse, keyboard navigation, and selection.
//!
//! Run with: zig build run-tree-example

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;

const Cx = gooey.Cx;
const Color = gooey.Color;
const TreeListState = gooey.TreeListState;
const TreeEntry = gooey.TreeEntry;
const Button = gooey.Button;

const ui = gooey.ui;

const Svg = gooey.Svg;
const Icons = gooey.Icons;

// =============================================================================
// Constants
// =============================================================================

const ITEM_HEIGHT: f32 = 28.0;
const INDENT_PX: f32 = 20.0;

// =============================================================================
// Application State
// =============================================================================

const State = struct {
    /// Retained state for the tree list
    tree: TreeListState = TreeListState.init(ITEM_HEIGHT),

    /// Store labels for each node (in real app, this would be your data model)
    labels: [256][64]u8 = undefined,
    label_count: u32 = 0,

    /// Track if tree has been initialized
    initialized: bool = false,

    // =========================================================================
    // Initialization
    // =========================================================================

    pub fn init(self: *State) void {
        if (self.initialized) return;

        // Build sample file tree structure
        // src/
        //   main.zig
        //   lib.zig
        //   widgets/
        //     button.zig
        //     tree_list.zig
        //     text_input.zig
        //   ui/
        //     styles.zig
        //     builder.zig
        // tests/
        //   widget_tests.zig
        //   integration_tests.zig
        // README.md
        // build.zig
        // LICENSE

        const src = self.addRoot("src", true).?;
        _ = self.addChild(src, "main.zig", false);
        _ = self.addChild(src, "lib.zig", false);

        const widgets = self.addChild(src, "widgets", true).?;
        _ = self.addChild(widgets, "button.zig", false);
        _ = self.addChild(widgets, "tree_list.zig", false);
        _ = self.addChild(widgets, "text_input.zig", false);

        const ui_folder = self.addChild(src, "ui", true).?;
        _ = self.addChild(ui_folder, "styles.zig", false);
        _ = self.addChild(ui_folder, "builder.zig", false);

        const tests = self.addRoot("tests", true).?;
        _ = self.addChild(tests, "widget_tests.zig", false);
        _ = self.addChild(tests, "integration_tests.zig", false);

        _ = self.addRoot("README.md", false);
        _ = self.addRoot("build.zig", false);
        _ = self.addRoot("LICENSE", false);

        // Expand src folder by default
        self.tree.expandNode(src);
        self.tree.rebuild();

        self.initialized = true;
    }

    // =========================================================================
    // Tree Building Helpers
    // =========================================================================

    fn addRoot(self: *State, name: []const u8, is_folder: bool) ?u32 {
        const node_idx = self.tree.addRoot(is_folder) orelse return null;
        self.setLabel(node_idx, name);
        return node_idx;
    }

    fn addChild(self: *State, parent: u32, name: []const u8, is_folder: bool) ?u32 {
        const node_idx = self.tree.addChild(parent, is_folder) orelse return null;
        self.setLabel(node_idx, name);
        return node_idx;
    }

    fn setLabel(self: *State, idx: u32, name: []const u8) void {
        const len = @min(name.len, 63);
        @memcpy(self.labels[idx][0..len], name[0..len]);
        self.labels[idx][len] = 0;
        if (idx >= self.label_count) self.label_count = idx + 1;
    }

    pub fn getLabel(self: *const State, idx: u32) []const u8 {
        if (idx >= self.label_count) return "";
        return std.mem.sliceTo(&self.labels[idx], 0);
    }

    // =========================================================================
    // Event Handlers
    // =========================================================================

    pub fn onSelect(self: *State, entry_index: u32) void {
        self.tree.selectIndex(entry_index);
    }

    pub fn onToggle(self: *State, entry_index: u32) void {
        self.tree.toggleExpand(entry_index);
    }

    pub fn expandAll(self: *State) void {
        self.tree.expandAll();
        self.tree.rebuild();
    }

    pub fn collapseAll(self: *State) void {
        self.tree.collapseAll();
        self.tree.rebuild();
    }

    pub fn selectPrevious(self: *State) void {
        self.tree.selectPrevious();
    }

    pub fn selectNext(self: *State) void {
        self.tree.selectNext();
    }

    pub fn navigateLeft(self: *State) void {
        self.tree.navigateLeft();
    }

    pub fn navigateRight(self: *State) void {
        self.tree.navigateRight();
    }
};

// =============================================================================
// Global State
// =============================================================================

var state = State{};

// =============================================================================
// Components
// =============================================================================

const Header = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const theme = cx.builder().theme();

        cx.render(ui.hstack(.{ .gap = 8, .alignment = .center }, .{
            ui.text("Tree List Demo", .{
                .size = 18,
                .weight = .bold,
                .color = theme.text,
            }),
            ui.spacer(),
            ui.text("File browser style hierarchical view", .{
                .size = 12,
                .color = theme.muted,
            }),
        }));
    }
};

const StatsBar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.stateConst(State);
        const theme = cx.builder().theme();

        // Format stats
        var buf: [256]u8 = undefined;
        const selected_text = if (s.tree.selected_index) |idx|
            if (idx < s.tree.entry_count)
                s.getLabel(s.tree.entries[idx].node_index)
            else
                "none"
        else
            "none";

        const stats = std.fmt.bufPrint(&buf, "Nodes: {d} | Visible: {d} | Selected: {s}", .{
            s.tree.node_count,
            s.tree.entry_count,
            selected_text,
        }) catch "Stats error";

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .symmetric = .{ .x = 12, .y = 8 } },
            .background = theme.surface,
            .corner_radius = 4,
        }, .{
            ui.text(stats, .{ .size = 12, .color = theme.muted }),
        }));
    }
};

const TreeView = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(State);
        const theme = cx.builder().theme();

        cx.treeList(
            "file-tree",
            &s.tree,
            .{
                .fill_width = true,
                .grow_height = true,
                .background = theme.surface,
                .corner_radius = 8,
                .padding = .{ .all = 4 },
                .indent_px = INDENT_PX,
            },
            renderTreeItem,
        );
    }

    fn renderTreeItem(entry: *const TreeEntry, cx: *Cx) void {
        const s = cx.stateConst(State);
        const theme = cx.builder().theme();

        // Find entry index for handlers
        const entry_index = getEntryIndex(entry, s);
        const is_selected = s.tree.selected_index == entry_index;

        // Calculate indentation
        const indent = @as(f32, @floatFromInt(entry.depth)) * INDENT_PX;

        // Get label
        const label = s.getLabel(entry.node_index);

        // Chevron for folders (use SVG icons)
        const show_chevron = entry.is_folder;
        const chevron_icon = if (entry.is_expanded) Icons.chevron_down else Icons.chevron_right;

        // Background color
        const bg_color = if (is_selected)
            theme.primary
        else
            Color.transparent;

        const text_color = if (is_selected) Color.white else theme.text;
        const chevron_color = if (is_selected) Color.white else theme.muted;

        // IMPORTANT: Height must match item_height_px
        cx.render(ui.box(.{
            .fill_width = true,
            .height = ITEM_HEIGHT,
            .background = bg_color,
            .padding = .{ .each = .{ .top = 0, .right = 8, .bottom = 0, .left = 4 } },
            .corner_radius = 4,
            .hover_background = if (is_selected) theme.primary else theme.overlay,
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 0,
            .on_click_handler = cx.updateWith(State, entry_index, State.onSelect),
        }, .{
            // Indent spacer
            ui.box(.{
                .width = indent,
                .height = ITEM_HEIGHT,
            }, .{}),
            // Chevron is clickable to toggle expand/collapse
            ui.box(.{
                .width = 18,
                .height = ITEM_HEIGHT,
                .alignment = .{ .main = .center, .cross = .center },
                .on_click_handler = if (entry.is_folder)
                    cx.updateWith(State, entry_index, State.onToggle)
                else
                    null,
            }, .{
                ui.when(show_chevron, .{
                    Svg{ .path = chevron_icon, .size = 12, .color = chevron_color },
                }),
                ui.when(!show_chevron, .{
                    ui.box(.{ .width = 12, .height = 12 }, .{}),
                }),
            }),
            // Folder/file icon
            ui.box(.{
                .width = 20,
                .height = ITEM_HEIGHT,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.when(!entry.is_folder, .{
                    Svg{ .path = Icons.file, .size = 16, .color = theme.muted },
                }),
                ui.when(entry.is_folder and entry.is_expanded, .{
                    Svg{ .path = Icons.folder_open, .size = 16, .color = theme.primary },
                }),
                ui.when(entry.is_folder and !entry.is_expanded, .{
                    Svg{ .path = Icons.folder, .size = 16, .color = theme.primary },
                }),
            }),
            ui.text(label, .{ .size = 14, .color = text_color }),
        }));
    }

    fn getEntryIndex(entry: *const TreeEntry, s: *const State) u32 {
        // Find the index of this entry in the entries array
        const entries_ptr = @intFromPtr(&s.tree.entries[0]);
        const entry_ptr = @intFromPtr(entry);
        const offset = entry_ptr - entries_ptr;
        return @intCast(offset / @sizeOf(TreeEntry));
    }
};

const Controls = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 8 }, .{
            Button{
                .label = "Expand All",
                .on_click_handler = cx.update(State, State.expandAll),
            },
            Button{
                .label = "Collapse All",
                .on_click_handler = cx.update(State, State.collapseAll),
            },
            ui.spacer(),
            Button{
                .label = "← Left",
                .on_click_handler = cx.update(State, State.navigateLeft),
            },
            Button{
                .label = "→ Right",
                .on_click_handler = cx.update(State, State.navigateRight),
            },
            Button{
                .label = "↑ Up",
                .on_click_handler = cx.update(State, State.selectPrevious),
            },
            Button{
                .label = "↓ Down",
                .on_click_handler = cx.update(State, State.selectNext),
            },
        }));
    }
};

const KeyboardHint = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const theme = cx.builder().theme();

        cx.render(ui.box(.{
            .fill_width = true,
            .padding = .{ .all = 8 },
            .background = theme.surface,
            .corner_radius = 4,
        }, .{
            ui.text("Keyboard: ↑↓ to navigate, ←→ to collapse/expand | Click chevron to toggle", .{
                .size = 11,
                .color = theme.muted,
            }),
        }));
    }
};

// =============================================================================
// Main Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(State);
    s.init();

    const size = cx.windowSize();
    const theme = cx.builder().theme();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .background = theme.bg,
        .padding = .{ .all = 16 },
        .direction = .column,
        .gap = 12,
    }, .{
        Header{},
        StatsBar{},
        TreeView{},
        Controls{},
        KeyboardHint{},
    }));
}

// =============================================================================
// Entry Point
// =============================================================================

const App = gooey.App(State, &state, render, .{
    .title = "TreeList Example - File Browser",
    .width = 600,
    .height = 500,
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
