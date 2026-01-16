//! CodeEditor Example
//!
//! Demonstrates the CodeEditor component with:
//! - File sidebar using UniformList
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
const UniformListState = gooey.UniformListState;

// =============================================================================
// Constants
// =============================================================================

const MAX_FILES: u32 = 500;
const FILE_ITEM_HEIGHT: f32 = 28.0;
const SIDEBAR_WIDTH: f32 = 220.0;

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
// Application State
// =============================================================================

const AppState = struct {
    source_code: []const u8 = sample_code,
    file_list_state: UniformListState = UniformListState.init(0, FILE_ITEM_HEIGHT),
    selected_file_index: ?u32 = null,

    // Directory state
    dir_path: [512]u8 = undefined,
    dir_path_len: usize = 0,

    // File entries storage (fixed capacity)
    file_names: [MAX_FILES][128]u8 = undefined,
    file_name_lens: [MAX_FILES]u8 = [_]u8{0} ** MAX_FILES,
    file_is_dir: [MAX_FILES]bool = [_]bool{false} ** MAX_FILES,
    file_count: u32 = 0,

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

    pub fn selectFile(self: *AppState, g: *gooey.Gooey, index: u32) void {
        if (index >= self.file_count) return;

        self.selected_file_index = index;

        // Don't try to load directories
        if (self.file_is_dir[index]) return;

        // Build full file path
        const dir_path = self.getDirPath();
        if (dir_path.len == 0) return;

        const file_name = self.getFileName(index);
        if (file_name.len == 0) return;

        var path_buf: [640]u8 = undefined;
        const full_path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir_path, file_name }) catch return;

        // Read file contents
        const file = std.fs.openFileAbsolute(full_path, .{}) catch return;
        defer file.close();

        const stat = file.stat() catch return;
        if (stat.size > 1024 * 1024) return; // Skip files > 1MB

        // Use a static buffer for file contents (simple approach for demo)
        const content = file.readToEndAlloc(std.heap.page_allocator, 1024 * 1024) catch return;

        // Store in state
        self.source_code = content;

        // Update the code editor widget directly
        if (g.codeEditor("source")) |editor| {
            editor.setText(content) catch {};
        }
    }

    pub fn openDirectory(self: *AppState, g: *gooey.Gooey) void {
        _ = self;
        // Use deferCommand to run the dialog after current event handling completes.
        // This avoids mutex deadlock since modal dialogs run their own event loop.
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

        // Clear existing files
        self.file_count = 0;
        self.selected_file_index = null;

        // Open and read directory
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch {
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (self.file_count >= MAX_FILES) break;

            // Skip hidden files
            if (entry.name.len > 0 and entry.name[0] == '.') continue;

            const idx = self.file_count;
            const name_len = @min(entry.name.len, 127);
            @memcpy(self.file_names[idx][0..name_len], entry.name[0..name_len]);
            self.file_name_lens[idx] = @intCast(name_len);
            self.file_is_dir[idx] = entry.kind == .directory;
            self.file_count += 1;
        }

        // Sort files: directories first, then alphabetically
        self.sortFiles();

        // Update list state with new count
        self.file_list_state = UniformListState.init(self.file_count, FILE_ITEM_HEIGHT);
    }

    fn sortFiles(self: *AppState) void {
        // Simple bubble sort (good enough for small file counts)
        if (self.file_count <= 1) return;

        var i: u32 = 0;
        while (i < self.file_count - 1) : (i += 1) {
            var j: u32 = 0;
            while (j < self.file_count - i - 1) : (j += 1) {
                const should_swap = blk: {
                    // Directories come first
                    if (self.file_is_dir[j] != self.file_is_dir[j + 1]) {
                        break :blk !self.file_is_dir[j]; // swap if j is not dir but j+1 is
                    }
                    // Then sort alphabetically (case-insensitive)
                    const name_a = self.file_names[j][0..self.file_name_lens[j]];
                    const name_b = self.file_names[j + 1][0..self.file_name_lens[j + 1]];
                    break :blk std.ascii.lessThanIgnoreCase(name_b, name_a);
                };

                if (should_swap) {
                    // Swap entries
                    const tmp_name = self.file_names[j];
                    const tmp_len = self.file_name_lens[j];
                    const tmp_is_dir = self.file_is_dir[j];

                    self.file_names[j] = self.file_names[j + 1];
                    self.file_name_lens[j] = self.file_name_lens[j + 1];
                    self.file_is_dir[j] = self.file_is_dir[j + 1];

                    self.file_names[j + 1] = tmp_name;
                    self.file_name_lens[j + 1] = tmp_len;
                    self.file_is_dir[j + 1] = tmp_is_dir;
                }
            }
        }
    }

    pub fn getFileName(self: *const AppState, index: u32) []const u8 {
        if (index >= self.file_count) return "";
        return self.file_names[index][0..self.file_name_lens[index]];
    }

    pub fn getDirPath(self: *const AppState) []const u8 {
        if (self.dir_path_len == 0) return "";
        return self.dir_path[0..self.dir_path_len];
    }

    pub fn getDirName(self: *const AppState) []const u8 {
        const path = self.getDirPath();
        if (path.len == 0) return "No folder open";
        // Find last path separator
        var i: usize = path.len;
        while (i > 0) : (i -= 1) {
            if (path[i - 1] == '/') {
                return path[i..];
            }
        }
        return path;
    }
};

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
            // Open folder button
            Button{
                .label = "📂 Open Folder",
                .variant = .secondary,
                .on_click_handler = cx.command(AppState, AppState.openDirectory),
            },

            // Directory name header
            ui.text(s.getDirName(), .{
                .size = 13,
                .weight = .bold,
                .color = text_color,
            }),

            // File count
            ui.textFmt("{d} items", .{s.file_count}, .{
                .size = 11,
                .color = text_muted,
            }),

            // File list using cx.uniformList()
            FileListContent{},
        }));
    }
};

const FileListContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        const s = cx.state(AppState);

        cx.uniformList(
            "file-list",
            &s.file_list_state,
            .{
                .fill_width = true,
                .grow_height = true,
                .corner_radius = 4,
            },
            renderFileItem,
        );
    }

    fn renderFileItem(index: u32, cx: *Cx) void {
        const s = cx.stateConst(AppState);
        const is_selected = if (s.selected_file_index) |sel| sel == index else false;

        const bg_color = if (is_selected)
            Color.rgba(0.3, 0.5, 1.0, 0.4)
        else
            Color.rgba(0, 0, 0, 0);

        const item_text_color = if (is_selected) text_color else text_muted;

        // Get actual file name from state
        const file_name = s.getFileName(index);
        if (file_name.len == 0) return;

        // File icon based on type
        const is_dir = if (index < s.file_count) s.file_is_dir[index] else false;
        const icon = if (is_dir) "📁" else "📄";

        cx.render(ui.box(.{
            .fill_width = true,
            .height = FILE_ITEM_HEIGHT,
            .background = bg_color,
            .hover_background = Color.rgba(1, 1, 1, 0.1),
            .corner_radius = 4,
            .padding = .{ .symmetric = .{ .x = 8, .y = 0 } },
            .direction = .row,
            .alignment = .{ .main = .start, .cross = .center },
            .gap = 8,
            .on_click_handler = cx.commandWith(AppState, index, AppState.selectFile),
        }, .{
            ui.text(icon, .{ .size = 12, .color = item_text_color }),
            ui.text(file_name, .{ .size = 13, .color = item_text_color }),
        }));
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
                ui.text(if (s.selected_file_index) |idx| s.getFileName(idx) else "No file selected", .{
                    .size = 14,
                    .weight = .bold,
                    .color = text_color,
                }),
                ui.spacer(),
                ui.text("Zig", .{
                    .size = 12,
                    .color = text_muted,
                }),
            }),

            // Code editor
            CodeEditor{
                .id = "source",
                .placeholder = "Enter your code here...",
                .bind = @constCast(&s.source_code),
                .width = self.editor_width - 16, // subtract padding
                .height = self.editor_height - 50, // subtract header and padding
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
        // Left sidebar with file list
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
    .glass_style = .blur,
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
