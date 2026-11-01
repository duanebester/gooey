//! Code editor on the 0.4.0 core: a `CodeEditor` beside the files of a
//! folder chosen with the native folder dialog (decision 13).
//!
//! The sidebar lists the folder's files in a `List`, which builds only the
//! rows in view; a click opens the file in the editor, or says why it cannot
//! show it. 0.3.1's file tree, glass, and CRT shader are not part of the port.
//!
//! Every byte is reserved before the event loop: the file list, the folder
//! path, and the read buffer live in `State`, and the editor's engine comes
//! from the one editor slot this app's limits reserve. Reading a folder or a
//! file runs on the main thread inside its handler, bounded by
//! `file_count_max` entries and `file_bytes_max` bytes.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const core = gooey.core;
const ui = core.ui;
const Cx = core.Cx;
const Effects = core.Effects;
const Color = ui.Color;
const Button = components.core.Button;
const CodeEditor = components.core.CodeEditor;
const List = components.core.List;
const Lucide = components.Lucide;

const assert = std.debug.assert;

/// Largest file the editor opens: the editor slot's bytes.
pub const file_bytes_max = 256 * 1024;
/// Files the sidebar lists; a folder's further files are not listed.
pub const file_count_max = 256;
/// Directory entries one folder load reads, hidden files and folders included.
const entry_scan_max = 4 * file_count_max;
/// Longest folder path kept; a longer chosen path is not opened.
const folder_bytes_max = 512;
/// Longest file name listed; longer names are skipped, never cut.
const name_bytes_max = 128;
const extension_bytes_max = 16;

const sidebar_width: f32 = 240;
const window_width = 1000;
const window_height = 700;
const outer_padding: f32 = 16;
const panel_gap: f32 = 12;
const panel_padding: f32 = 8;
const header_height: f32 = 50;
const editor_width: f32 = window_width - sidebar_width - outer_padding * 2 - panel_gap -
    panel_padding * 2;
const editor_height: f32 = window_height - outer_padding * 2 - header_height;

comptime {
    assert(editor_width > 0);
    assert(editor_height > 0);
    assert(file_bytes_max <= limits.text.editor.bytes_max);
}

/// The `small` profile with one editor: profiles reserve none, since a
/// 256 KiB editor slot (and its undo copy) is too large to reserve unasked.
pub const limits = blk: {
    var value = core.ResourceLimits.small;
    value.text.editor = .{ .count_max = 1, .bytes_max = file_bytes_max, .undo_depth_max = 128 };
    break :blk value;
};

pub const FileStatus = enum {
    displaying_code,
    binary_file,
    image_file,
    file_too_large,
    line_too_long,

    fn message(self: FileStatus) []const u8 {
        return switch (self) {
            .displaying_code => "",
            .binary_file => "Binary files cannot be displayed",
            .image_file => "Image preview not yet supported",
            .file_too_large => "File is too large to display (>256 KiB)",
            .line_too_long => std.fmt.comptimePrint(
                "Line too long to display (>{d} characters)",
                .{gooey.text.run_codepoint_count_max},
            ),
        };
    }
};

const FileName = struct {
    bytes: [name_bytes_max]u8 = @splat(0),
    len: u8 = 0,

    pub fn text(self: *const FileName) []const u8 {
        return self.bytes[0..self.len];
    }

    fn lessThan(_: void, a: FileName, b: FileName) bool {
        return std.ascii.lessThanIgnoreCase(a.text(), b.text());
    }
};

pub const State = struct {
    source: []const u8 = sample_code,
    status: FileStatus = .displaying_code,
    extension_bytes: [extension_bytes_max]u8 = @splat(0),
    extension_len: u8 = 0,
    folder_bytes: [folder_bytes_max]u8 = @splat(0),
    folder_len: u32 = 0,
    files: [file_count_max]FileName = @splat(.{}),
    file_count: u32 = 0,
    selected: ?u32 = null,
    /// One byte past the largest file, so a full read means "too large".
    read_bytes: [file_bytes_max + 1]u8 = @splat(0),

    pub fn openFolder(_: *State, effects: *Effects) void {
        effects.openFileDialog(.{
            .kind = .{ .open = .{ .files = false, .directories = true, .multiple = false } },
            .on_complete = effects.handler(State.folderChosen),
        });
    }

    /// A cancelled or failed dialog leaves the current folder, as in 0.3.1.
    pub fn folderChosen(self: *State, effects: *Effects) void {
        const completion = effects.completionEvent().?;
        switch (completion.outcome) {
            .file_selected => |paths| self.loadFolder(io(), paths.first()),
            .cancelled, .failed => {},
        }
    }

    /// List the folder's visible files, sorted. A folder that cannot be
    /// read lists none.
    pub fn loadFolder(self: *State, folder_io: std.Io, path: []const u8) void {
        assert(path.len > 0);
        if (path.len > folder_bytes_max) return;
        @memcpy(self.folder_bytes[0..path.len], path);
        self.folder_len = @intCast(path.len);
        self.file_count = 0;
        self.selected = null;
        var directory = std.Io.Dir.openDirAbsolute(folder_io, path, .{ .iterate = true }) catch
            return;
        defer directory.close(folder_io);
        var entries = directory.iterate();
        var scanned: u32 = 0;
        while (scanned < entry_scan_max) : (scanned += 1) {
            const entry = (entries.next(folder_io) catch break) orelse break;
            if (entry.kind == .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.name.len > name_bytes_max) continue;
            if (self.file_count == file_count_max) break;
            const file = &self.files[self.file_count];
            @memcpy(file.bytes[0..entry.name.len], entry.name);
            file.len = @intCast(entry.name.len);
            self.file_count += 1;
        }
        std.mem.sort(FileName, self.files[0..self.file_count], {}, FileName.lessThan);
        assert(self.file_count <= file_count_max);
    }

    /// Show file `index` in the editor, or why it cannot be shown. A file
    /// that cannot be read leaves the editor as it was, as in 0.3.1.
    pub fn openFile(self: *State, index: u32) void {
        if (index >= self.file_count) return;
        self.selected = index;
        const name = self.files[index].text();
        self.setExtension(extensionOf(name));
        if (isBinaryExtension(self.extension())) {
            self.status = if (isImageExtension(self.extension())) .image_file else .binary_file;
            self.source = "";
            return;
        }
        var path_buffer: [folder_bytes_max + 1 + name_bytes_max]u8 = undefined;
        // The folder and name each fit their maximum, so the join fits.
        const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}", .{ self.folder(), name }) catch
            unreachable;
        const content = std.Io.Dir.cwd().readFile(io(), path, &self.read_bytes) catch return;
        if (content.len == self.read_bytes.len) {
            self.status = .file_too_large;
            self.source = "";
        } else if (!std.unicode.utf8ValidateSlice(content)) {
            self.status = .binary_file;
            self.source = "";
        } else if (longestLine(content) > gooey.text.run_codepoint_count_max) {
            // The editor paints a line as one shaped run, which fails fast
            // past the shapers' bound; refuse the file instead.
            self.status = .line_too_long;
            self.source = "";
        } else {
            self.status = .displaying_code;
            self.source = content;
        }
    }

    fn setExtension(self: *State, value: []const u8) void {
        const kept = @min(value.len, extension_bytes_max);
        @memcpy(self.extension_bytes[0..kept], value[0..kept]);
        self.extension_len = @intCast(kept);
    }

    fn extension(self: *const State) []const u8 {
        return self.extension_bytes[0..self.extension_len];
    }

    fn folder(self: *const State) []const u8 {
        return self.folder_bytes[0..self.folder_len];
    }

    fn folderName(self: *const State) []const u8 {
        const path = self.folder();
        if (path.len == 0) return "No folder open";
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
        return path[slash + 1 ..];
    }

    fn selectedName(self: *const State) []const u8 {
        const index = self.selected orelse return "No file selected";
        assert(index < self.file_count);
        return self.files[index].text();
    }

    const sample_code =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    const allocator = std.heap.page_allocator;
        \\
        \\    var list = std.ArrayList(i32).init(allocator);
        \\    defer list.deinit();
        \\
        \\    try list.append(42);
        \\    try list.append(100);
        \\
        \\    for (list.items) |item| {
        \\        std.debug.print("{d}\n", .{item});
        \\    }
        \\}
    ;
};

/// Handlers carry no `Io`; the main thread reads through the process's
/// single-threaded one, which blocks the handler for the read alone.
fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn extensionOf(name: []const u8) []const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return "";
    return name[dot + 1 ..];
}

fn matchesAny(extension: []const u8, comptime list: []const []const u8) bool {
    if (extension.len > extension_bytes_max) return false;
    var lower_buffer: [extension_bytes_max]u8 = undefined;
    const lower = std.ascii.lowerString(&lower_buffer, extension);
    for (list) |candidate| {
        if (std.mem.eql(u8, lower, candidate)) return true;
    }
    return false;
}

const image_extensions = [_][]const u8{
    "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "tif", "ico",
};

fn isImageExtension(extension: []const u8) bool {
    return matchesAny(extension, &image_extensions);
}

/// The codepoints in `content`'s longest line.
fn longestLine(content: []const u8) u32 {
    var longest: u32 = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| longest = @max(longest, gooey.text.codepointCount(line));
    assert(longest <= content.len);
    return longest;
}

fn isBinaryExtension(extension: []const u8) bool {
    return matchesAny(extension, &(image_extensions ++ [_][]const u8{
        "svg",   "pdf", "doc",  "docx", "xls", "xlsx",   "ppt",   "pptx", "zip",
        "tar",   "gz",  "7z",   "rar",  "bz2", "xz",     "exe",   "dll",  "so",
        "dylib", "o",   "a",    "lib",  "obj", "mp3",    "mp4",   "wav",  "avi",
        "mov",   "mkv", "flac", "ogg",  "m4a", "m4v",    "ttf",   "otf",  "woff",
        "woff2", "eot", "bin",  "dat",  "db",  "sqlite", "class", "pyc",  "pyd",
    }));
}

// =============================================================================
// Rendering
// =============================================================================

const text_color = Color.rgba(1, 1, 1, 0.95);
const text_muted = Color.rgba(1, 1, 1, 0.6);
const selected_background = Color.rgba(0.3, 0.5, 1.0, 0.4);
const hover_background = Color.rgba(1, 1, 1, 0.1);

pub const App = core.App(State, render, .{
    .title = "Code Editor",
    .width = window_width,
    .height = window_height,
    .limits = limits,
    .theme = &core.Theme.dark,
    .fonts = .{ .limits = core.FontLimits.small },
});

/// The generated entry point (contract §7).
pub const main = App.main;

pub fn render(cx: *Cx) void {
    cx.render(ui.box(.{ .style = .{
        .direction = .row,
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(outer_padding),
        .gap = panel_gap,
        .background = .{ .rgba = Color.rgb(0.08, 0.08, 0.12) },
    } }, .{
        Sidebar{},
        EditorPanel{},
    }));
}

const Sidebar = struct {
    pub fn render(_: Sidebar, cx: *Cx) void {
        const s = cx.state(State);
        var count_buffer: [32]u8 = undefined;
        // 32 bytes hold any u32 and " items".
        const count = std.fmt.bufPrint(&count_buffer, "{d} items", .{s.file_count}) catch
            unreachable;
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = sidebar_width },
            .height = .{ .grow = 1 },
            .background = .{ .rgba = Color.rgba(0, 0, 0, 0.3) },
            .corner_radius = .all(8),
            .padding = .all(8),
            .gap = 8,
        } }, .{
            Button{
                .label = "Open Folder",
                .variant = .secondary,
                .on_click = cx.on(State.openFolder, .{}),
            },
            ui.text(s.folderName(), .{
                .size = 13,
                .weight = .bold,
                .color = .{ .rgba = text_color },
            }),
            ui.text(count, .{ .size = 11, .color = .{ .rgba = text_muted } }),
            List(FileRow){ .key = "files", .count = s.file_count },
        }));
    }
};

const FileRow = struct {
    index: u32,

    pub const row_height: f32 = 26;

    const file_icon = Icon{ .path = Lucide.file };
    const file_icon_lit = Icon{ .path = Lucide.file, .lit_color = true };

    pub fn render(self: FileRow, cx: *Cx) void {
        const s = cx.state(State);
        assert(self.index < s.file_count);
        const key = core.Key{ .name = "file" };
        const selected = s.selected == self.index;
        const hovered = cx.hovered(cx.id(key));
        const name = s.files[self.index].text();
        const color = if (selected) text_color else text_muted;
        const background = if (selected)
            selected_background
        else if (hovered) hover_background else Color.transparent;
        cx.render(ui.box(.{
            .key = key,
            .on_click = cx.on(State.openFile, .{ .arg = self.index }),
            .a11y = .{ .role = .button, .label = name },
            .style = .{
                .direction = .row,
                .width = .{ .grow = 1 },
                .height = .{ .grow = 1 },
                .padding = .{ .left = 20, .right = 8 },
                .gap = 4,
                .alignment = .center_cross,
                .background = .{ .rgba = background },
                .corner_radius = .all(4),
                .cursor = .pointer,
            },
        }, .{
            ui.paint(Icon, if (selected) &file_icon_lit else &file_icon, Icon.paint, .{
                .width = .{ .fixed = 14 },
                .height = .{ .fixed = 14 },
            }),
            ui.text(name, .{ .size = 12, .color = .{ .rgba = color } }),
        }));
    }
};

/// A Lucide outline icon in the muted colour, or the text colour when lit.
const Icon = struct {
    path: []const u8,
    lit_color: bool = false,
    stroke_width: f32 = 1.5,

    fn paint(self: *const Icon, painter: *ui.Painter) void {
        assert(self.path.len > 0);
        const color = if (self.lit_color) text_color else text_muted;
        painter.svg(self.path, painter.bounds, .{
            .fill = null,
            .stroke = color,
            .stroke_width = self.stroke_width,
        });
    }
};

const EditorPanel = struct {
    pub fn render(_: EditorPanel, cx: *Cx) void {
        const s = cx.state(State);
        const language = if (s.status == .displaying_code) "Zig" else s.extension();
        cx.render(ui.box(.{ .style = .{
            .width = .{ .grow = 1 },
            .height = .{ .grow = 1 },
            .padding = .all(panel_padding),
            .gap = 8,
        } }, .{
            ui.box(.{ .style = .{ .direction = .row, .width = .{ .grow = 1 }, .gap = 8 } }, .{
                ui.text(s.selectedName(), .{
                    .size = 14,
                    .weight = .bold,
                    .color = .{ .rgba = text_color },
                }),
                ui.box(.{ .style = .{ .width = .{ .grow = 1 } } }, .{}),
                ui.text(language, .{ .size = 12, .color = .{ .rgba = text_muted } }),
            }),
            ui.when(s.status == .displaying_code, editorView),
            ui.when(s.status != .displaying_code, statusView),
        }));
    }

    /// The editor fills the panel: its rows are what fits above the status
    /// bar at this font's line height.
    fn editorView(cx: *Cx) void {
        const s = cx.state(State);
        const line_height = cx.fontMetrics().line_height;
        // Border and padding above and below the text, then the status bar
        // and its one-pixel rule.
        const chrome: f32 = 2 * 1 + 2 * 8 + 22 + 1;
        const rows: u16 = @intFromFloat(@max(1, @floor((editor_height - chrome) / line_height)));
        cx.render(CodeEditor{
            .key = "source",
            .bind = &s.source,
            .placeholder = "Enter your code here...",
            .width = editor_width,
            .rows = rows,
            .show_line_numbers = true,
            .gutter_width = 50,
            .tab_size = 4,
            .use_hard_tabs = false,
            .show_status_bar = true,
            .language_mode = "Zig",
            .encoding = "UTF-8",
        });
    }

    fn statusView(cx: *Cx) void {
        const s = cx.state(State);
        const icon = switch (s.status) {
            .displaying_code => unreachable,
            .binary_file => &status_icons[0],
            .image_file => &status_icons[1],
            .file_too_large, .line_too_long => &status_icons[2],
        };
        cx.render(ui.box(.{ .style = .{
            .width = .{ .fixed = editor_width },
            .height = .{ .fixed = editor_height },
            .background = .{ .rgba = Color.rgba(0, 0, 0, 0.2) },
            .corner_radius = .all(8),
            .gap = 16,
            .alignment = .center,
        } }, .{
            ui.paint(Icon, icon, Icon.paint, .{
                .width = .{ .fixed = 48 },
                .height = .{ .fixed = 48 },
            }),
            ui.text(s.status.message(), .{
                .size = 16,
                .weight = .medium,
                .color = .{ .rgba = text_muted },
            }),
        }));
    }

    const status_icons = [_]Icon{
        .{ .path = Lucide.triangle_alert },
        .{ .path = Lucide.image },
        .{ .path = Lucide.circle_alert },
    };
};
