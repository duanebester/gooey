//! File Dialog Example
//!
//! Demonstrates:
//! - Opening files with NSOpenPanel
//! - Saving files with NSSavePanel
//! - Different dialog options (multiple selection, directories, file types)

const std = @import("std");
const gooey = @import("gooey");
const file_dialog = gooey.platform.mac.file_dialog;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    last_action: []const u8 = "No file selected yet",
    // Store up to 10 paths for display
    path_storage: [10][256]u8 = undefined,
    path_lens: [10]usize = [_]usize{0} ** 10,
    path_count: usize = 0,

    pub fn openSingleFile(self: *AppState) void {
        self.clearPaths();

        if (file_dialog.promptForPaths(std.heap.page_allocator, .{
            .files = true,
            .directories = false,
            .multiple = false,
            .prompt = "Open",
            .message = "Select a file to open",
        })) |result| {
            defer result.deinit();
            self.last_action = "Opened single file:";
            self.storePaths(result.paths);
        } else {
            self.last_action = "Open cancelled";
        }
    }

    pub fn openMultipleFiles(self: *AppState) void {
        self.clearPaths();

        if (file_dialog.promptForPaths(std.heap.page_allocator, .{
            .files = true,
            .directories = false,
            .multiple = true,
            .prompt = "Select",
            .message = "Select multiple files",
            .allowed_extensions = &.{ "zig", "txt", "md", "json" },
        })) |result| {
            defer result.deinit();
            self.last_action = "Opened multiple files:";
            self.storePaths(result.paths);
        } else {
            self.last_action = "Open cancelled";
        }
    }

    pub fn openDirectory(self: *AppState) void {
        self.clearPaths();

        if (file_dialog.promptForPaths(std.heap.page_allocator, .{
            .files = false,
            .directories = true,
            .multiple = false,
            .prompt = "Choose",
            .message = "Select a directory",
        })) |result| {
            defer result.deinit();
            self.last_action = "Selected directory:";
            self.storePaths(result.paths);
        } else {
            self.last_action = "Directory selection cancelled";
        }
    }

    pub fn saveFile(self: *AppState) void {
        self.clearPaths();

        if (file_dialog.promptForNewPath(std.heap.page_allocator, .{
            .suggested_name = "untitled.txt",
            .prompt = "Save",
            .message = "Choose where to save your file",
            .allowed_extensions = &.{ "txt", "md" },
        })) |path| {
            defer std.heap.page_allocator.free(path);
            self.last_action = "Save location:";
            self.storePath(path);
        } else {
            self.last_action = "Save cancelled";
        }
    }

    fn clearPaths(self: *AppState) void {
        self.path_count = 0;
        for (&self.path_lens) |*len| {
            len.* = 0;
        }
    }

    fn storePaths(self: *AppState, paths: []const []const u8) void {
        for (paths) |path| {
            if (self.path_count >= 10) break;
            self.storePath(path);
        }
    }

    fn storePath(self: *AppState, path: []const u8) void {
        if (self.path_count >= 10) return;
        const max_len = @min(path.len, 255);
        @memcpy(self.path_storage[self.path_count][0..max_len], path[0..max_len]);
        self.path_lens[self.path_count] = max_len;
        self.path_count += 1;
    }

    fn getPath(self: *const AppState, index: usize) []const u8 {
        if (index >= self.path_count) return "";
        return self.path_storage[index][0..self.path_lens[index]];
    }
};

// =============================================================================
// Entry Points
// =============================================================================

var state = AppState{};

const App = gooey.App(AppState, &state, render, .{
    .title = "File Dialog Demo",
    .width = 700,
    .height = 450,
});

pub fn main() !void {
    return App.main();
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    cx.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .gap = 24,
        .direction = .column,
        .background = ui.Color.rgb(0.12, 0.12, 0.14),
    }, .{
        // Title
        ui.text("File Dialog Demo", .{
            .size = 28,
            .color = ui.Color.white,
        }),

        // Description
        ui.text("Native macOS file dialogs using NSOpenPanel / NSSavePanel", .{
            .size = 14,
            .color = ui.Color.rgb(0.6, 0.6, 0.6),
        }),

        // Buttons row
        ButtonRow{},

        // Results section
        ResultsPanel{ .state = s },
    });
}

// =============================================================================
// Components
// =============================================================================

const ButtonRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.hstack(.{ .gap = 12 }, .{
            Button{
                .label = "Open File",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.openSingleFile),
            },
            Button{
                .label = "Open Multiple",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.openMultipleFiles),
            },
            Button{
                .label = "Open Directory",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.openDirectory),
            },
            Button{
                .label = "Save As...",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.saveFile),
            },
        });
    }
};

const ResultsPanel = struct {
    state: *const AppState,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.box(.{
            .direction = .column,
            .gap = 8,
            .padding = .{ .all = 16 },
            .background = ui.Color.rgba(1, 1, 1, 0.05),
            .corner_radius = 8,
            .grow = true,
        }, .{
            // Status message
            ui.text(self.state.last_action, .{
                .size = 16,
                .color = ui.Color.rgb(0.7, 0.8, 0.9),
            }),

            // Path list
            PathList{ .state = self.state },
        });
    }
};

const PathList = struct {
    state: *const AppState,

    pub fn render(self: @This(), cx: *Cx) void {
        if (self.state.path_count == 0) return;

        cx.box(.{
            .direction = .column,
            .gap = 4,
            .padding = .{ .each = .{ .top = 8, .right = 0, .bottom = 0, .left = 0 } },
        }, .{
            PathItem{ .state = self.state, .index = 0 },
            PathItem{ .state = self.state, .index = 1 },
            PathItem{ .state = self.state, .index = 2 },
            PathItem{ .state = self.state, .index = 3 },
            PathItem{ .state = self.state, .index = 4 },
            PathItem{ .state = self.state, .index = 5 },
            PathItem{ .state = self.state, .index = 6 },
            PathItem{ .state = self.state, .index = 7 },
            PathItem{ .state = self.state, .index = 8 },
            PathItem{ .state = self.state, .index = 9 },
        });
    }
};

const PathItem = struct {
    state: *const AppState,
    index: usize,

    pub fn render(self: @This(), b: *gooey.Builder) void {
        if (self.index >= self.state.path_count) return;

        const path = self.state.getPath(self.index);
        if (path.len == 0) return;

        // Truncate long paths for display
        const display = if (path.len > 70) blk: {
            // Show "...end_of_path"
            break :blk path[path.len - 67 ..];
        } else path;

        b.box(.{}, .{
            ui.text(display, .{
                .size = 13,
                .color = ui.Color.rgb(0.6, 0.8, 0.6),
            }),
        });
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AppState path storage" {
    var s = AppState{};

    s.storePath("/Users/test/file.txt");
    try std.testing.expectEqual(@as(usize, 1), s.path_count);
    try std.testing.expectEqualStrings("/Users/test/file.txt", s.getPath(0));

    s.clearPaths();
    try std.testing.expectEqual(@as(usize, 0), s.path_count);
}
