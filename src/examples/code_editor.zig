//! CodeEditor Example
//!
//! Demonstrates the CodeEditor component with:
//! - File sidebar using TreeList for hierarchical browsing
//! - Liquid glass transparency effect
//! - CRT shader post-processing
//! - Native file dialog to open directories
//!
//! Run with: zig build run-code-editor

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const file_dialog = gooey.platform.mac.file_dialog;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Color = gooey.Color;
const Button = gooey.Button;
const CodeEditor = gooey.CodeEditor;
const TreeListState = gooey.TreeListState;
const TreeEntry = gooey.TreeEntry;
const Svg = gooey.Svg;
const Lucide = gooey.components.Lucide;

// =============================================================================
// Constants
// =============================================================================

const MAX_NODES: u32 = 2048;
const FILE_ITEM_HEIGHT: f32 = 26.0;
const SIDEBAR_WIDTH: f32 = 240.0;
const INDENT_PX: f32 = 16.0;

// =============================================================================
// CRT Shader (MSL - macOS)
// =============================================================================

const crt_shader_msl =
    \\void mainImage(thread float4& fragColor, float2 fragCoord,
    \\               constant ShaderUniforms& uniforms,
    \\               texture2d<float> iChannel0,
    \\               sampler iChannel0Sampler) {
    \\    float2 uv = fragCoord / uniforms.iResolution.xy;
    \\
    \\    // Subtle CRT barrel distortion
    \\    float2 center = uv - 0.5;
    \\    float dist = dot(center, center);
    \\    uv = uv + center * dist * 0.1;
    \\
    \\    // Sample with chromatic aberration, preserve alpha
    \\    float4 original = iChannel0.sample(iChannel0Sampler, uv);
    \\    float4 color;
    \\    color.r = iChannel0.sample(iChannel0Sampler, uv + float2(0.002, 0.0)).r;
    \\    color.g = original.g;
    \\    color.b = iChannel0.sample(iChannel0Sampler, uv - float2(0.002, 0.0)).b;
    \\    color.a = original.a; // Preserve alpha for glass transparency
    \\
    \\    // Visible scanlines (every ~3 pixels)
    \\    float scanline = sin(fragCoord.y * 0.7) * 0.5 + 0.5;
    \\    scanline = pow(scanline, 1.5) * 0.15 + 0.85;
    \\    color.rgb *= scanline;
    \\
    \\    // Animated vertical sync roll
    \\    float roll = sin(uniforms.iTime * 0.5) * 0.002;
    \\    color.rgb += roll;
    \\
    \\    // Flickering
    \\    float flicker = sin(uniforms.iTime * 15.0) * 0.02 + 1.0;
    \\    color.rgb *= flicker;
    \\
    \\    // Vignette
    \\    float vignette = 1.0 - dist * 1.5;
    \\    color.rgb *= vignette;
    \\
    \\    fragColor = color;
    \\}
;

// =============================================================================
// CRT Shader (WGSL - Web)
// =============================================================================

const crt_shader_wgsl =
    \\fn mainImage(
    \\    fragCoord: vec2<f32>,
    \\    u: ShaderUniforms,
    \\    tex: texture_2d<f32>,
    \\    samp: sampler
    \\) -> vec4<f32> {
    \\    var uv = fragCoord / u.iResolution.xy;
    \\
    \\    // Barrel distortion
    \\    let center = uv - 0.5;
    \\    let dist = dot(center, center);
    \\    uv = uv + center * dist * 0.1;
    \\
    \\    let original = textureSample(tex, samp, uv);
    \\    var color = original.rgb;
    \\
    \\    // Scanlines
    \\    let scanline = sin(fragCoord.y * 2.0) * 0.04;
    \\    color = color - scanline;
    \\
    \\    // Vignette
    \\    let vignette = 1.0 - dist * 1.5;
    \\    color = color * vignette;
    \\
    \\    // Chromatic aberration
    \\    let r = textureSample(tex, samp, uv + vec2<f32>(0.002, 0.0)).r;
    \\    let b = textureSample(tex, samp, uv - vec2<f32>(0.002, 0.0)).b;
    \\    color = vec3<f32>(r, color.g, b);
    \\
    \\    return vec4<f32>(color, original.a); // Preserve alpha for glass transparency
    \\}
;

// =============================================================================
// File Status
// =============================================================================

const FileStatus = enum {
    displaying_code, // Normal text file
    binary_file, // Can't display - binary/unknown
    image_file, // Could display image (future)
    file_too_large, // Exceeds size limit
    no_file_selected, // Nothing selected

    pub fn getMessage(self: FileStatus) []const u8 {
        return switch (self) {
            .displaying_code => "",
            .binary_file => "Binary files cannot be displayed",
            .image_file => "Image preview not yet supported",
            .file_too_large => "File is too large to display (>1MB)",
            .no_file_selected => "Select a file to view",
        };
    }

    pub fn getIconPath(self: FileStatus) []const u8 {
        return switch (self) {
            .displaying_code => Lucide.file,
            .binary_file => Lucide.triangle_alert,
            .image_file => Lucide.image,
            .file_too_large => Lucide.circle_alert,
            .no_file_selected => Lucide.file,
        };
    }
};

// =============================================================================
// Application State
// =============================================================================

const AppState = struct {
    source_code: []const u8 = sample_code,
    tree_state: TreeListState = TreeListState.initWithIndent(FILE_ITEM_HEIGHT, INDENT_PX),

    // File display state
    file_status: FileStatus = .displaying_code,
    current_file_ext: [16]u8 = undefined,
    current_file_ext_len: u8 = 0,

    // Directory state
    dir_path: [512]u8 = undefined,
    dir_path_len: usize = 0,

    // Node data: store file paths for each node
    node_paths: [MAX_NODES][512]u8 = undefined,
    node_path_lens: [MAX_NODES]u16 = [_]u16{0} ** MAX_NODES,
    node_names: [MAX_NODES][128]u8 = undefined,
    node_name_lens: [MAX_NODES]u8 = [_]u8{0} ** MAX_NODES,

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

    // =========================================================================
    // Node Data Helpers
    // =========================================================================

    fn setNodePath(self: *AppState, idx: u32, path: []const u8) void {
        const len = @min(path.len, 511);
        @memcpy(self.node_paths[idx][0..len], path[0..len]);
        self.node_path_lens[idx] = @intCast(len);
    }

    fn setNodeName(self: *AppState, idx: u32, name: []const u8) void {
        const len = @min(name.len, 127);
        @memcpy(self.node_names[idx][0..len], name[0..len]);
        self.node_name_lens[idx] = @intCast(len);
    }

    pub fn getNodePath(self: *const AppState, idx: u32) []const u8 {
        if (idx >= MAX_NODES) return "";
        return self.node_paths[idx][0..self.node_path_lens[idx]];
    }

    pub fn getNodeName(self: *const AppState, idx: u32) []const u8 {
        if (idx >= MAX_NODES) return "";
        return self.node_names[idx][0..self.node_name_lens[idx]];
    }

    // =========================================================================
    // File Selection
    // =========================================================================

    pub fn onSelect(self: *AppState, entry_index: u32) void {
        self.tree_state.selectIndex(entry_index);
    }

    pub fn onToggle(self: *AppState, entry_index: u32) void {
        self.tree_state.toggleExpand(entry_index);
    }

    pub fn onItemClick(self: *AppState, g: *gooey.Gooey, entry_index: u32) void {
        self.tree_state.selectIndex(entry_index);

        // Get the selected entry
        if (self.tree_state.getEntry(entry_index)) |entry| {
            const node_idx = entry.node_index;
            const is_folder = entry.is_folder;

            if (is_folder) {
                // Toggle folder expansion
                self.tree_state.toggleExpand(entry_index);
            } else {
                // Open file
                self.openFile(g, node_idx);
            }
        }
    }

    fn openFile(self: *AppState, g: *gooey.Gooey, node_idx: u32) void {
        const path = self.getNodePath(node_idx);
        if (path.len == 0) return;

        // Store the extension for display
        const ext = getFileExtension(path);
        const ext_len: u8 = @intCast(@min(ext.len, 15));
        @memcpy(self.current_file_ext[0..ext_len], ext[0..ext_len]);
        self.current_file_ext_len = ext_len;

        // Check if it's a binary/image file by extension
        if (isBinaryExtension(ext)) {
            if (isImageExtension(ext)) {
                self.file_status = .image_file;
            } else {
                self.file_status = .binary_file;
            }
            // Clear the editor content
            self.source_code = "";
            if (g.codeEditor("source")) |editor| {
                editor.setText("") catch {};
            }
            return;
        }

        // Read file contents
        const file = std.fs.openFileAbsolute(path, .{}) catch return;
        defer file.close();

        const stat = file.stat() catch return;
        if (stat.size > 1024 * 1024) {
            self.file_status = .file_too_large;
            self.source_code = "";
            if (g.codeEditor("source")) |editor| {
                editor.setText("") catch {};
            }
            return;
        }

        const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return;

        // Validate UTF-8 before setting - this prevents crashes in the text shaper
        if (!std.unicode.utf8ValidateSlice(content)) {
            self.file_status = .binary_file;
            self.source_code = "";
            if (g.codeEditor("source")) |editor| {
                editor.setText("") catch {};
            }
            return;
        }

        self.file_status = .displaying_code;
        self.source_code = content;

        // Update the code editor widget directly
        if (g.codeEditor("source")) |editor| {
            editor.setText(content) catch {};
        }
    }

    // =========================================================================
    // Directory Operations
    // =========================================================================

    pub fn openDirectory(self: *AppState, g: *gooey.Gooey) void {
        _ = self;
        g.deferCommand(AppState, AppState.openDialogDeferred);
    }

    fn openDialogDeferred(self: *AppState, g: *gooey.Gooey) void {
        _ = g;
        if (file_dialog.promptForPaths(std.heap.page_allocator, .{
            .files = false,
            .directories = true,
            .multiple = false,
            .prompt = "Open",
            .message = "Select a directory to browse",
        })) |result| {
            defer result.deinit();
            if (result.paths.len > 0) {
                self.loadDirectory(result.paths[0]);
            }
        }
    }

    pub fn loadDirectory(self: *AppState, path: []const u8) void {
        // Store directory path
        const path_len = @min(path.len, self.dir_path.len);
        @memcpy(self.dir_path[0..path_len], path[0..path_len]);
        self.dir_path_len = path_len;

        // Clear tree state
        self.tree_state.clear();

        // Build tree from directory
        self.buildTreeFromDirectory(path, null);

        // Rebuild flattened view
        self.tree_state.rebuild();
    }

    const DirEntry = struct { name: [128]u8, len: u8 };

    fn buildTreeFromDirectory(self: *AppState, path: []const u8, parent: ?u32) void {
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return;
        defer dir.close();

        // Collect entries for sorting
        var dirs: [256]DirEntry = undefined;
        var files: [256]DirEntry = undefined;
        var dir_count: u32 = 0;
        var file_count: u32 = 0;

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            // Skip hidden files
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            const name_len = @min(entry.name.len, 127);
            if (entry.kind == .directory) {
                if (dir_count < 256) {
                    @memcpy(dirs[dir_count].name[0..name_len], entry.name[0..name_len]);
                    dirs[dir_count].len = @intCast(name_len);
                    dir_count += 1;
                }
            } else {
                if (file_count < 256) {
                    @memcpy(files[file_count].name[0..name_len], entry.name[0..name_len]);
                    files[file_count].len = @intCast(name_len);
                    file_count += 1;
                }
            }
        }

        // Sort directories alphabetically
        self.sortEntries(dirs[0..dir_count]);
        // Sort files alphabetically
        self.sortEntries(files[0..file_count]);

        // Add directories first
        for (dirs[0..dir_count]) |d| {
            const name = d.name[0..d.len];
            const node_idx = if (parent) |p|
                self.tree_state.addChild(p, true)
            else
                self.tree_state.addRoot(true);

            if (node_idx) |idx| {
                self.setNodeName(idx, name);

                // Build full path
                var full_path: [640]u8 = undefined;
                const full_len = std.fmt.bufPrint(&full_path, "{s}/{s}", .{ path, name }) catch continue;
                self.setNodePath(idx, full_len);

                // Recursively add children (but don't expand by default)
                self.buildTreeFromDirectory(full_len, idx);
            }
        }

        // Add files
        for (files[0..file_count]) |f| {
            const name = f.name[0..f.len];
            const node_idx = if (parent) |p|
                self.tree_state.addChild(p, false)
            else
                self.tree_state.addRoot(false);

            if (node_idx) |idx| {
                self.setNodeName(idx, name);

                // Build full path
                var full_path: [640]u8 = undefined;
                const full_len = std.fmt.bufPrint(&full_path, "{s}/{s}", .{ path, name }) catch continue;
                self.setNodePath(idx, full_len);
            }
        }
    }

    fn sortEntries(self: *AppState, entries: []DirEntry) void {
        _ = self;
        if (entries.len <= 1) return;

        // Simple bubble sort (good enough for small counts)
        for (0..entries.len - 1) |i| {
            for (0..entries.len - i - 1) |j| {
                const name_a = entries[j].name[0..entries[j].len];
                const name_b = entries[j + 1].name[0..entries[j + 1].len];
                if (std.ascii.lessThanIgnoreCase(name_b, name_a)) {
                    const tmp = entries[j];
                    entries[j] = entries[j + 1];
                    entries[j + 1] = tmp;
                }
            }
        }
    }

    pub fn getDirPath(self: *const AppState) []const u8 {
        if (self.dir_path_len == 0) return "";
        return self.dir_path[0..self.dir_path_len];
    }

    pub fn getDirName(self: *const AppState) []const u8 {
        const path = self.getDirPath();
        if (path.len == 0) return "No folder open";
        var i: usize = path.len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/') {
                return path[i..];
            }
        }
        return path;
    }

    pub fn getSelectedFileName(self: *const AppState) []const u8 {
        if (self.tree_state.selected_index) |idx| {
            if (self.tree_state.getEntry(idx)) |entry| {
                return self.getNodeName(entry.node_index);
            }
        }
        return "No file selected";
    }

    // =========================================================================
    // Tree Navigation
    // =========================================================================

    pub fn expandAll(self: *AppState) void {
        self.tree_state.expandAll();
        self.tree_state.rebuild();
    }

    pub fn collapseAll(self: *AppState) void {
        self.tree_state.collapseAll();
        self.tree_state.rebuild();
    }

    pub fn getCurrentExtension(self: *const AppState) []const u8 {
        return self.current_file_ext[0..self.current_file_ext_len];
    }
};

// =============================================================================
// File Type Detection Helpers
// =============================================================================

fn getFileExtension(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0) : (i -= 1) {
        if (path[i - 1] == '.') {
            return path[i..];
        }
        if (path[i - 1] == '/' or path[i - 1] == '\\') {
            return "";
        }
    }
    return "";
}

fn isBinaryExtension(ext: []const u8) bool {
    const binary_exts = [_][]const u8{
        // Images
        "png",    "jpg",   "jpeg", "gif", "bmp",  "ico",   "webp", "tiff",  "tif",  "svg",
        // Documents
        "pdf",    "doc",   "docx", "xls", "xlsx", "ppt",   "pptx",
        // Archives
        "zip",   "tar",  "gz",
        "7z",     "rar",   "bz2",  "xz",
        // Executables/Libraries
         "exe",  "dll",   "so",   "dylib", "o",    "a",
        "lib",    "obj",
        // Media
          "mp3",  "mp4", "wav",  "avi",   "mov",  "mkv",   "flac", "ogg",
        "m4a",    "m4v",
        // Fonts
          "ttf",  "otf", "woff", "woff2", "eot",
        // Other binary
         "bin",   "dat",  "db",
        "sqlite", "class", "pyc",  "pyd",
    };

    // Convert to lowercase for comparison
    var lower_buf: [16]u8 = undefined;
    const len = @min(ext.len, 16);
    for (0..len) |i| {
        lower_buf[i] = std.ascii.toLower(ext[i]);
    }
    const lower_ext = lower_buf[0..len];

    for (binary_exts) |bin_ext| {
        if (std.mem.eql(u8, lower_ext, bin_ext)) return true;
    }
    return false;
}

fn isImageExtension(ext: []const u8) bool {
    const img_exts = [_][]const u8{ "png", "jpg", "jpeg", "gif", "bmp", "webp", "tiff", "tif", "ico" };

    // Convert to lowercase for comparison
    var lower_buf: [16]u8 = undefined;
    const len = @min(ext.len, 16);
    for (0..len) |i| {
        lower_buf[i] = std.ascii.toLower(ext[i]);
    }
    const lower_ext = lower_buf[0..len];

    for (img_exts) |img_ext| {
        if (std.mem.eql(u8, lower_ext, img_ext)) return true;
    }
    return false;
}

// =============================================================================
// Colors
// =============================================================================

const text_color = Color.rgba(1, 1, 1, 0.95);
const text_muted = Color.rgba(1, 1, 1, 0.6);
const sidebar_bg = Color.rgba(0, 0, 0, 0.3);
const editor_bg = Color.rgba(0, 0, 0, 0);
const clear = Color.rgba(0, 0, 0, 0);

// =============================================================================
// Global State
// =============================================================================

var state = AppState{};

// =============================================================================
// Components
// =============================================================================

const FileSidebar = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .width = SIDEBAR_WIDTH,
            .grow_height = true,
            .background = sidebar_bg,
            .corner_radius = 8,
            .padding = .{ .all = 8 },
            .direction = .column,
            .gap = 8,
        }, .{
            // Header with buttons
            ui.hstack(.{ .gap = 4 }, .{
                Button{
                    .label = "📂 Open",
                    .variant = .secondary,
                    .on_click_handler = cx.command(AppState, AppState.openDirectory),
                },
                ui.spacer(),
                ui.when(s.dir_path_len > 0, .{
                    ui.box(.{
                        .width = 28,
                        .height = 28,
                        .corner_radius = 4,
                        .alignment = .{ .main = .center, .cross = .center },
                        .hover_background = Color.rgba(1, 1, 1, 0.1),
                        .on_click_handler = cx.update(AppState, AppState.expandAll),
                    }, .{
                        Svg{ .path = Lucide.folder_open, .size = 16, .no_fill = true, .stroke_color = text_muted, .stroke_width = 1.5 },
                    }),
                    ui.box(.{
                        .width = 28,
                        .height = 28,
                        .corner_radius = 4,
                        .alignment = .{ .main = .center, .cross = .center },
                        .hover_background = Color.rgba(1, 1, 1, 0.1),
                        .on_click_handler = cx.update(AppState, AppState.collapseAll),
                    }, .{
                        Svg{ .path = Lucide.folder, .size = 16, .no_fill = true, .stroke_color = text_muted, .stroke_width = 1.5 },
                    }),
                }),
            }),

            // Directory name header
            ui.text(s.getDirName(), .{
                .size = 13,
                .weight = .bold,
                .color = text_color,
            }),

            // Node count
            ui.textFmt("{d} items", .{s.tree_state.node_count}, .{
                .size = 11,
                .color = text_muted,
            }),

            // Tree list
            TreeListContent{},
        }));
    }
};

const TreeListContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.treeList(
            "file-tree",
            &s.tree_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .corner_radius = 4,
                .indent_px = INDENT_PX,
            },
            renderTreeItem,
        );
    }

    fn renderTreeItem(entry: *const TreeEntry, cx: *Cx) void {
        const s = cx.stateConst(AppState);

        // Find entry index
        const entry_index = getEntryIndex(entry, s);
        const is_selected = s.tree_state.selected_index == entry_index;

        // Calculate indentation
        const indent = @as(f32, @floatFromInt(entry.depth)) * INDENT_PX;

        // Get label
        const label = s.getNodeName(entry.node_index);

        // Colors
        const bg_color = if (is_selected)
            Color.rgba(0.3, 0.5, 1.0, 0.4)
        else
            Color.transparent;

        const item_text_color = if (is_selected) text_color else text_muted;
        const icon_color = if (is_selected) text_color else text_muted;

        // Chevron for folders
        const show_chevron = entry.is_folder;

        cx.render(ui.box(.{
            .fill_width = true,
            .height = FILE_ITEM_HEIGHT,
            .background = bg_color,
            .hover_background = Color.rgba(1, 1, 1, 0.1),
            .corner_radius = 4,
            .padding = .{ .each = .{ .top = 0, .right = 8, .bottom = 0, .left = 4 } },
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 0,
            .on_click_handler = cx.commandWith(AppState, entry_index, AppState.onItemClick),
        }, .{
            // Indent spacer
            ui.box(.{ .width = indent, .height = FILE_ITEM_HEIGHT }, .{}),

            // Chevron (clickable for folders)
            ui.box(.{
                .width = 16,
                .height = FILE_ITEM_HEIGHT,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.when(show_chevron, .{
                    ui.when(entry.is_expanded, .{
                        Svg{ .path = Lucide.chevron_down, .size = 12, .no_fill = true, .stroke_color = icon_color, .stroke_width = 1.5 },
                    }),
                    ui.when(!entry.is_expanded, .{
                        Svg{ .path = Lucide.chevron_right, .size = 12, .no_fill = true, .stroke_color = icon_color, .stroke_width = 1.5 },
                    }),
                }),
            }),

            // File/folder icon
            ui.box(.{
                .width = 18,
                .height = FILE_ITEM_HEIGHT,
                .alignment = .{ .main = .center, .cross = .center },
            }, .{
                ui.when(!entry.is_folder, .{
                    Svg{ .path = Lucide.file, .size = 14, .no_fill = true, .stroke_color = icon_color, .stroke_width = 1.5 },
                }),
                ui.when(entry.is_folder and entry.is_expanded, .{
                    Svg{ .path = Lucide.folder_open, .size = 14, .no_fill = true, .stroke_color = Color.rgba(0.4, 0.7, 1.0, 1.0), .stroke_width = 1.5 },
                }),
                ui.when(entry.is_folder and !entry.is_expanded, .{
                    Svg{ .path = Lucide.folder, .size = 14, .no_fill = true, .stroke_color = Color.rgba(0.4, 0.7, 1.0, 1.0), .stroke_width = 1.5 },
                }),
            }),

            // Gap
            ui.box(.{ .width = 4 }, .{}),

            // File name
            ui.text(label, .{ .size = 12, .color = item_text_color }),
        }));
    }

    fn getEntryIndex(entry: *const TreeEntry, s: *const AppState) u32 {
        const entries_ptr = @intFromPtr(&s.tree_state.entries[0]);
        const entry_ptr = @intFromPtr(entry);
        const offset = entry_ptr - entries_ptr;
        return @intCast(offset / @sizeOf(TreeEntry));
    }
};

const EditorPanel = struct {
    editor_width: f32,
    editor_height: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.render(ui.box(.{
            .width = self.editor_width,
            .height = self.editor_height,
            .background = editor_bg,
            .corner_radius = 8,
            .padding = .{ .all = 8 },
            .direction = .column,
            .gap = 8,
        }, .{
            // Editor header - show selected file name
            ui.hstack(.{ .gap = 8 }, .{
                ui.text(s.getSelectedFileName(), .{
                    .size = 14,
                    .weight = .bold,
                    .color = text_color,
                }),
                ui.spacer(),
                ui.text(if (s.file_status == .displaying_code) "Zig" else s.getCurrentExtension(), .{
                    .size = 12,
                    .color = text_muted,
                }),
            }),

            // Code editor (shown when displaying code)
            ui.when(s.file_status == .displaying_code, .{
                CodeEditor{
                    .id = "source",
                    .placeholder = "Enter your code here...",
                    .bind = @constCast(&s.source_code),
                    .width = self.editor_width - 16,
                    .height = self.editor_height - 50,
                    .show_line_numbers = true,
                    .gutter_width = 50,
                    .tab_size = 4,
                    .use_hard_tabs = false,
                    .show_status_bar = true,
                    .language_mode = "Zig",
                    .encoding = "UTF-8",
                    .current_line_background = Color.rgba(0.3, 0.5, 1.0, 0.08),
                    .background = clear,
                    .gutter_background = clear,
                    .status_bar_background = clear,
                    .text_color = Color.white,
                    .line_number_color = text_muted,
                    .current_line_number_color = Color.white,
                    .cursor_color = Color.white,
                    .status_bar_text_color = text_muted,
                },
            }),

            // Status message (shown when file cannot be displayed)
            ui.when(s.file_status != .displaying_code, .{
                ui.box(.{
                    .width = self.editor_width - 16,
                    .height = self.editor_height - 50,
                    .background = Color.rgba(0, 0, 0, 0.2),
                    .corner_radius = 8,
                    .alignment = .{ .main = .center, .cross = .center },
                }, .{
                    ui.vstack(.{ .gap = 16, .alignment = .center }, .{
                        Svg{
                            .path = s.file_status.getIconPath(),
                            .size = 48,
                            .no_fill = true,
                            .stroke_color = text_muted,
                            .stroke_width = 1.5,
                        },
                        ui.text(s.file_status.getMessage(), .{
                            .size = 16,
                            .color = text_muted,
                            .weight = .medium,
                        }),
                    }),
                }),
            }),
        }));
    }
};

// =============================================================================
// Main Render Function
// =============================================================================

fn render(cx: *Cx) void {
    const size = cx.windowSize();

    // Calculate editor panel dimensions
    const padding: f32 = 16;
    const gap: f32 = 12;
    const editor_width = size.width - SIDEBAR_WIDTH - (padding * 2) - gap;
    const editor_height = size.height - (padding * 2);

    cx.render(ui.box(.{
        .width = size.width,
        .height = size.height,
        .padding = .{ .all = padding },
        .direction = .row,
        .gap = gap,
    }, .{
        // Left sidebar with tree list
        FileSidebar{},

        // Main editor panel
        EditorPanel{
            .editor_width = editor_width,
            .editor_height = editor_height,
        },
    }));
}

// =============================================================================
// Entry Point
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Code Editor",
    .width = 1000,
    .height = 700,
    // Glass effect
    .background_color = Color.init(0.08, 0.08, 0.12, 1.0),
    .background_opacity = 0.3,
    .glass_style = .glass_regular,
    .glass_corner_radius = 10.0,
    .titlebar_transparent = true,
    .full_size_content = false,
    // CRT shader
    .custom_shaders = &.{.{ .msl = crt_shader_msl, .wgsl = crt_shader_wgsl }},
});

comptime {
    _ = App;
}

pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
