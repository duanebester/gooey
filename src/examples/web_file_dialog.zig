//! Web File Dialog Example
//!
//! Demonstrates:
//! - Opening files with <input type="file">
//! - Opening multiple files
//! - Saving/downloading files
//! - Async callback pattern for web file dialogs
//!
//! Note: On web, file dialogs are async and return file CONTENTS
//! (not paths, due to browser security restrictions).

const std = @import("std");
const builtin = @import("builtin");
const gooey = @import("gooey");

/// WASM-compatible logging - redirect std.log to console.log via JS imports
pub const std_options: std.Options = if (builtin.os.tag == .freestanding)
    .{ .logFn = gooey.wasmLogFn }
else
    .{};
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = gooey.Button;

// Web-specific file dialog
const file_dialog = if (platform.is_wasm) platform.web.file_dialog else struct {};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    status: []const u8 = "Select a file to get started",
    file_name: [256]u8 = undefined,
    file_name_len: usize = 0,
    content_preview: [512]u8 = undefined,
    content_preview_len: usize = 0,
    file_count: usize = 0,
    pending_request: ?u32 = null,

    pub fn getFileName(self: *const AppState) []const u8 {
        if (self.file_name_len == 0) return "";
        return self.file_name[0..self.file_name_len];
    }

    pub fn getContentPreview(self: *const AppState) []const u8 {
        if (self.content_preview_len == 0) return "";
        return self.content_preview[0..self.content_preview_len];
    }

    pub fn setFileName(self: *AppState, name: []const u8) void {
        const len = @min(name.len, 255);
        @memcpy(self.file_name[0..len], name[0..len]);
        self.file_name_len = len;
    }

    pub fn setContentPreview(self: *AppState, content: []const u8) void {
        const len = @min(content.len, 511);
        @memcpy(self.content_preview[0..len], content[0..len]);
        self.content_preview_len = len;
    }

    pub fn clear(self: *AppState) void {
        self.file_name_len = 0;
        self.content_preview_len = 0;
        self.file_count = 0;
        self.pending_request = null;
    }

    // Button handlers
    pub fn openSingleFile(self: *AppState) void {
        if (!platform.is_wasm) {
            self.status = "File dialogs only work in browser";
            return;
        }

        ensureFileDialogInit();
        self.clear();
        self.status = "Opening file dialog...";

        if (file_dialog.openSingleFileAsync(".txt,.md,.zig,.json,.csv", onFileDialogComplete)) |req_id| {
            self.pending_request = req_id;
        } else {
            self.status = "Failed to open file dialog";
        }
    }

    pub fn openMultipleFiles(self: *AppState) void {
        if (!platform.is_wasm) {
            self.status = "File dialogs only work in browser";
            return;
        }

        ensureFileDialogInit();
        self.clear();
        self.status = "Opening file dialog...";

        if (file_dialog.openMultipleFilesAsync(".txt,.md,.zig,.json", onFileDialogComplete)) |req_id| {
            self.pending_request = req_id;
        } else {
            self.status = "Failed to open file dialog";
        }
    }

    pub fn openAnyFile(self: *AppState) void {
        if (!platform.is_wasm) {
            self.status = "File dialogs only work in browser";
            return;
        }

        ensureFileDialogInit();
        self.clear();
        self.status = "Opening file dialog...";

        if (file_dialog.openSingleFileAsync(null, onFileDialogComplete)) |req_id| {
            self.pending_request = req_id;
        } else {
            self.status = "Failed to open file dialog";
        }
    }

    pub fn saveExampleFile(self: *AppState) void {
        if (!platform.is_wasm) {
            self.status = "File dialogs only work in browser";
            return;
        }

        ensureFileDialogInit();
        const content = "Hello from Gooey!\n\nThis file was saved from a WASM application.\nThe file dialog uses the browser's download mechanism.\n";
        file_dialog.saveFile("gooey-example.txt", content);
        self.status = "Download triggered: gooey-example.txt";
    }

    pub fn saveJsonFile(self: *AppState) void {
        if (!platform.is_wasm) {
            self.status = "File dialogs only work in browser";
            return;
        }

        ensureFileDialogInit();
        const json =
            \\{
            \\  "app": "Gooey",
            \\  "platform": "WebAssembly",
            \\  "features": ["file_dialog", "wgpu", "ui"],
            \\  "message": "Exported from web app!"
            \\}
        ;
        file_dialog.saveFile("gooey-data.json", json);
        self.status = "Download triggered: gooey-data.json";
    }
};

// Global state
var state = AppState{};

// Callback for file dialog completion
fn onFileDialogComplete(request_id: u32, result: ?file_dialog.WebFileDialogResult) void {
    _ = request_id;

    if (result) |res| {
        var r = res; // Make mutable for deinit
        defer r.deinit();

        if (r.files.len == 0) {
            state.status = "No files selected";
            return;
        }

        state.file_count = r.files.len;

        // Store first file's info
        const first = r.files[0];
        state.setFileName(first.name);

        // Create a preview of the content (first 500 chars, text only)
        if (isTextContent(first.content)) {
            state.setContentPreview(first.content);
        } else {
            state.setContentPreview("[Binary file - cannot preview]");
        }

        if (r.files.len == 1) {
            state.status = "Opened 1 file";
        } else {
            state.status = "Opened multiple files (showing first)";
        }
    } else {
        state.status = "File selection cancelled";
    }
    state.pending_request = null;
}

fn isTextContent(content: []const u8) bool {
    // Simple heuristic: check for null bytes in first 100 chars
    const check_len = @min(content.len, 100);
    for (content[0..check_len]) |c| {
        if (c == 0) return false;
    }
    return true;
}

// =============================================================================
// Entry Points
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Web File Dialog Demo",
    .width = 700,
    .height = 500,
});

// Force type analysis - triggers @export on WASM
comptime {
    _ = App;
}

// Native entry point
pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}

// WASM initialization - called after main init
var file_dialog_initialized: bool = false;

fn ensureFileDialogInit() void {
    if (!file_dialog_initialized and platform.is_wasm) {
        file_dialog.init(std.heap.page_allocator);
        file_dialog_initialized = true;
    }
}

// =============================================================================
// Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const s = cx.state(AppState);
    const size = cx.windowSize();

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = 32 },
        .gap = 24,
        .direction = .column,
        .background = ui.Color.rgb(0.12, 0.12, 0.14),
    }, .{
        // Title
        ui.text("Web File Dialog Demo", .{
            .size = 28,
            .color = ui.Color.white,
        }),

        // Description
        ui.text("Browser file dialogs using <input type=\"file\"> and Blob downloads", .{
            .size = 14,
            .color = ui.Color.rgb(0.6, 0.6, 0.6),
        }),

        // Open buttons row
        OpenButtonRow{},

        // Save buttons row
        SaveButtonRow{},

        // Results section
        ResultsPanel{ .state = s },
    }));
}

// =============================================================================
// Components
// =============================================================================

const OpenButtonRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 12 }, .{
            ui.text("Open:", .{
                .size = 14,
                .color = ui.Color.rgb(0.7, 0.7, 0.7),
            }),
            Button{
                .label = "Text Files",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.openSingleFile),
            },
            Button{
                .label = "Multiple Files",
                .variant = .primary,
                .on_click_handler = cx.update(AppState, AppState.openMultipleFiles),
            },
            Button{
                .label = "Any File",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.openAnyFile),
            },
        }));
    }
};

const SaveButtonRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.hstack(.{ .gap = 12 }, .{
            ui.text("Save:", .{
                .size = 14,
                .color = ui.Color.rgb(0.7, 0.7, 0.7),
            }),
            Button{
                .label = "Download .txt",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.saveExampleFile),
            },
            Button{
                .label = "Download .json",
                .variant = .secondary,
                .on_click_handler = cx.update(AppState, AppState.saveJsonFile),
            },
        }));
    }
};

const ResultsPanel = struct {
    state: *const AppState,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .column,
            .gap = 12,
            .padding = .{ .all = 16 },
            .background = ui.Color.rgba(1, 1, 1, 0.05),
            .corner_radius = 8,
            .grow = true,
        }, .{
            // Status message
            ui.text(self.state.status, .{
                .size = 16,
                .color = ui.Color.rgb(0.7, 0.8, 0.9),
            }),

            // File info
            FileInfo{ .state = self.state },

            // Content preview
            ContentPreview{ .state = self.state },
        }));
    }
};

const FileInfo = struct {
    state: *const AppState,

    pub fn render(self: @This(), cx: *Cx) void {
        const name = self.state.getFileName();
        if (name.len == 0) return;

        cx.render(ui.hstack(.{ .gap = 8 }, .{
            ui.text("File:", .{
                .size = 14,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
            ui.text(name, .{
                .size = 14,
                .color = ui.Color.rgb(0.6, 0.9, 0.6),
            }),
        }));
    }
};

const ContentPreview = struct {
    state: *const AppState,

    pub fn render(self: @This(), cx: *Cx) void {
        const preview = self.state.getContentPreview();
        if (preview.len == 0) return;

        cx.render(ui.box(.{
            .direction = .column,
            .gap = 8,
            .padding = .{ .all = 12 },
            .background = ui.Color.rgba(0, 0, 0, 0.3),
            .corner_radius = 4,
            .grow = true,
        }, .{
            ui.text("Content Preview:", .{
                .size = 12,
                .color = ui.Color.rgb(0.5, 0.5, 0.5),
            }),
            ui.text(preview, .{
                .size = 13,
                .color = ui.Color.rgb(0.8, 0.8, 0.8),
            }),
        }));
    }
};

// =============================================================================
// Tests
// =============================================================================

test "AppState file name storage" {
    var s = AppState{};

    s.setFileName("test.txt");
    try std.testing.expectEqualStrings("test.txt", s.getFileName());

    s.clear();
    try std.testing.expectEqualStrings("", s.getFileName());
}

test "AppState content preview" {
    var s = AppState{};

    s.setContentPreview("Hello, world!");
    try std.testing.expectEqualStrings("Hello, world!", s.getContentPreview());
}
