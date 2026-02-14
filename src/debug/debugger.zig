//! UI Inspector/Debugger for Gooey
//!
//! Toggle with Cmd/Ctrl+Shift+I
//! - Inspector: Click elements to view properties
//! - Tree View: Hierarchical element tree with expand/collapse
//! - Profiler: Performance monitoring overlay
//!
//! ## Zero Allocation
//!
//! Following project guidelines, all debug overlays and formatted strings
//! use pre-allocated fixed-capacity arrays. No dynamic allocation after initialization.

const std = @import("std");
const platform_time = @import("../platform/time.zig");
const scene_mod = @import("../scene/scene.zig");
const input_mod = @import("../input/events.zig");
const layout_mod = @import("../layout/layout.zig");
const engine_mod = @import("../layout/engine.zig");
const types_mod = @import("../layout/types.zig");
const text_render = @import("../text/render.zig");
const render_stats = @import("render_stats.zig");

const Scene = scene_mod.Scene;
const Quad = scene_mod.Quad;
const Hsla = scene_mod.Hsla;
const BoundingBox = layout_mod.BoundingBox;
const KeyCode = input_mod.KeyCode;
const Modifiers = input_mod.Modifiers;
const LayoutElement = engine_mod.LayoutElement;
const ElementType = engine_mod.ElementType;
const SourceLoc = engine_mod.SourceLoc;
const SizingType = types_mod.SizingType;
const LayoutDirection = types_mod.LayoutDirection;

/// Debug rendering modes (removed bounds_only - not useful without inspector)
pub const DebugMode = enum {
    disabled,
    inspector_panel,
    profiler,
};

/// Frame timing snapshot for history
pub const FrameSnapshot = struct {
    frame_time_ns: u64 = 0,
    layout_time_ns: u64 = 0,
    tree_build_ns: u64 = 0,
    dispatch_sync_ns: u64 = 0,
    render_time_ns: u64 = 0,
    gpu_submit_ns: u64 = 0,
    atlas_upload_ns: u64 = 0,
    quads_rendered: u32 = 0,
    glyphs_rendered: u32 = 0,
    draw_calls: u32 = 0,
    shape_misses: u32 = 0,
    shape_time_ns: u64 = 0,
    shape_cache_hits: u32 = 0,
};

/// Cached element information for inspector display
pub const ElementInfo = struct {
    layout_id: u32 = 0,
    element_type: ElementType = .container,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
    content_x: f32 = 0,
    content_y: f32 = 0,
    content_width: f32 = 0,
    content_height: f32 = 0,
    width_sizing: SizingType = .fit,
    height_sizing: SizingType = .fit,
    width_min: f32 = 0,
    width_max: f32 = std.math.floatMax(f32),
    height_min: f32 = 0,
    height_max: f32 = std.math.floatMax(f32),
    padding_left: u16 = 0,
    padding_right: u16 = 0,
    padding_top: u16 = 0,
    padding_bottom: u16 = 0,
    child_gap: u16 = 0,
    child_count: u32 = 0,
    layout_direction: LayoutDirection = .left_to_right,
    z_index: i16 = 0,
    is_floating: bool = false,
    text_preview: [64]u8 = [_]u8{0} ** 64,
    text_preview_len: usize = 0,
    source_location: SourceLoc = .{},
    valid: bool = false,
};

/// Pre-allocated debug overlay state
pub const Debugger = struct {
    mode: DebugMode = .disabled,
    selected_layout_id: ?u32 = null,
    overlay_quads: [MAX_DEBUG_QUADS]Quad = undefined,
    overlay_count: u32 = 0,
    selected_element_info: ElementInfo = .{},
    layout_time_ns: u64 = 0,
    tree_build_ns: u64 = 0,
    dispatch_sync_ns: u64 = 0,
    render_time_ns: u64 = 0,
    gpu_submit_ns: u64 = 0,
    atlas_upload_ns: u64 = 0,
    frame_time_ns: u64 = 0,
    frame_history: [FRAME_HISTORY_SIZE]FrameSnapshot = [_]FrameSnapshot{.{}} ** FRAME_HISTORY_SIZE,
    frame_history_index: u32 = 0,
    frame_count: u64 = 0,
    fps_sample_start_ns: u64 = 0,
    fps_frame_count: u32 = 0,
    current_fps: f32 = 0.0,
    layout_start_ns: u64 = 0,
    tree_build_start_ns: u64 = 0,
    dispatch_sync_start_ns: u64 = 0,
    render_start_ns: u64 = 0,
    frame_start_ns: u64 = 0,
    fmt_buffers: [FMT_BUFFER_COUNT][FMT_BUFFER_SIZE]u8 = [_][FMT_BUFFER_SIZE]u8{[_]u8{0} ** FMT_BUFFER_SIZE} ** FMT_BUFFER_COUNT,
    fmt_buffer_index: usize = 0,

    const Self = @This();

    const MAX_DEBUG_QUADS = 128;
    const FRAME_HISTORY_SIZE: u32 = 60;
    const FPS_SAMPLE_INTERVAL_NS: u64 = 500_000_000;
    const FMT_BUFFER_COUNT = 32;
    const FMT_BUFFER_SIZE = 128;
    const PANEL_WIDTH: f32 = 280;
    const PANEL_PADDING: f32 = 12;
    const PANEL_MARGIN: f32 = 16;
    const PROFILER_WIDTH: f32 = 320;
    const PROFILER_HEIGHT: f32 = 320;
    const GRAPH_HEIGHT: f32 = 80;

    const COLOR_HOVER = Hsla.init(0.55, 0.9, 0.5, 0.25);
    const COLOR_HOVER_BORDER = Hsla.init(0.55, 1.0, 0.5, 0.8);
    const COLOR_SELECTED = Hsla.init(0.0, 0.9, 0.5, 0.15);
    const COLOR_SELECTED_BORDER = Hsla.init(0.0, 1.0, 0.5, 1.0);
    const COLOR_ANCESTOR = Hsla.init(0.3, 0.6, 0.5, 0.1);
    const COLOR_ANCESTOR_BORDER = Hsla.init(0.3, 0.8, 0.5, 0.4);
    const PANEL_BACKGROUND = Hsla.init(0.0, 0.0, 0.12, 0.92);
    const PANEL_BORDER = Hsla.init(0.0, 0.0, 0.3, 0.8);
    const TEXT_PRIMARY = Hsla.init(0.0, 0.0, 0.95, 1.0);
    const TEXT_SECONDARY = Hsla.init(0.0, 0.0, 0.6, 1.0);
    const TEXT_VALUE = Hsla.init(0.55, 0.7, 0.7, 1.0);
    const TEXT_LABEL = Hsla.init(0.3, 0.5, 0.6, 1.0);
    const TEXT_SELECTED = Hsla.init(0.08, 0.9, 0.6, 1.0);
    const BORDER_WIDTH: f32 = 2.0;
    const COLOR_FRAME_TIME = Hsla.init(0.55, 0.8, 0.6, 0.9);
    const COLOR_LAYOUT_TIME = Hsla.init(0.3, 0.8, 0.5, 0.9);
    const COLOR_TREE_BUILD = Hsla.init(0.45, 0.7, 0.55, 0.9);
    const COLOR_DISPATCH_SYNC = Hsla.init(0.75, 0.6, 0.55, 0.9);
    const COLOR_RENDER_TIME = Hsla.init(0.08, 0.8, 0.5, 0.9);
    const COLOR_GPU_SUBMIT = Hsla.init(0.6, 0.8, 0.45, 0.9);
    const COLOR_ATLAS_UPLOAD = Hsla.init(0.12, 0.7, 0.5, 0.9);
    const COLOR_TARGET_LINE = Hsla.init(0.0, 0.0, 0.5, 0.5);
    const COLOR_GOOD_FPS = Hsla.init(0.3, 0.8, 0.6, 1.0);
    const COLOR_OK_FPS = Hsla.init(0.15, 0.8, 0.5, 1.0);
    const COLOR_BAD_FPS = Hsla.init(0.0, 0.8, 0.5, 1.0);

    pub fn toggle(self: *Self) void {
        self.mode = switch (self.mode) {
            .disabled => .inspector_panel,
            .inspector_panel => .profiler,
            .profiler => .disabled,
        };
        if (self.mode == .disabled) {
            self.selected_layout_id = null;
            self.selected_element_info = .{};
        }
    }

    pub fn isActive(self: *const Self) bool {
        return self.mode != .disabled;
    }

    pub fn showInspector(self: *const Self) bool {
        return self.mode == .inspector_panel;
    }

    pub fn showProfiler(self: *const Self) bool {
        return self.mode == .profiler;
    }

    pub fn beginFrame(self: *Self) void {
        self.frame_start_ns = @intCast(platform_time.nanoTimestamp());
    }

    pub fn beginLayout(self: *Self) void {
        self.layout_start_ns = @intCast(platform_time.nanoTimestamp());
    }

    pub fn endLayout(self: *Self) void {
        const now: u64 = @intCast(platform_time.nanoTimestamp());
        self.layout_time_ns = now - self.layout_start_ns;
    }

    pub fn beginTreeBuild(self: *Self) void {
        self.tree_build_start_ns = @intCast(platform_time.nanoTimestamp());
    }

    pub fn endTreeBuild(self: *Self) void {
        const now: u64 = @intCast(platform_time.nanoTimestamp());
        self.tree_build_ns = now - self.tree_build_start_ns;
    }

    pub fn beginDispatchSync(self: *Self) void {
        self.dispatch_sync_start_ns = @intCast(platform_time.nanoTimestamp());
    }

    pub fn endDispatchSync(self: *Self) void {
        const now: u64 = @intCast(platform_time.nanoTimestamp());
        self.dispatch_sync_ns = now - self.dispatch_sync_start_ns;
    }

    pub fn beginRender(self: *Self) void {
        self.render_start_ns = @intCast(platform_time.nanoTimestamp());
    }

    pub fn endRender(self: *Self) void {
        const now: u64 = @intCast(platform_time.nanoTimestamp());
        self.render_time_ns = now - self.render_start_ns;
    }

    /// Report GPU-side timings from the previous frame.
    /// Called at the start of the current frame since GPU work
    /// happens after finalizeFrame in the window's renderFrame().
    pub fn reportGpuTimings(self: *Self, gpu_submit_ns: u64, atlas_upload_ns: u64) void {
        self.gpu_submit_ns = gpu_submit_ns;
        self.atlas_upload_ns = atlas_upload_ns;
    }

    pub fn endFrame(self: *Self, stats: ?*const render_stats.RenderStats) void {
        const now: u64 = @intCast(platform_time.nanoTimestamp());
        if (self.frame_start_ns > 0) {
            self.frame_time_ns = now - self.frame_start_ns;
        }
        const snapshot = FrameSnapshot{
            .frame_time_ns = self.frame_time_ns,
            .layout_time_ns = self.layout_time_ns,
            .tree_build_ns = self.tree_build_ns,
            .dispatch_sync_ns = self.dispatch_sync_ns,
            .render_time_ns = self.render_time_ns,
            .gpu_submit_ns = self.gpu_submit_ns,
            .atlas_upload_ns = self.atlas_upload_ns,
            .quads_rendered = if (stats) |s| s.quads_rendered else 0,
            .glyphs_rendered = if (stats) |s| s.glyphs_rendered else 0,
            .draw_calls = if (stats) |s| s.draw_calls else 0,
            .shape_misses = if (stats) |s| s.shape_misses else 0,
            .shape_time_ns = if (stats) |s| s.shape_time_ns else 0,
            .shape_cache_hits = if (stats) |s| s.shape_cache_hits else 0,
        };
        self.frame_history[self.frame_history_index] = snapshot;
        self.frame_history_index = (self.frame_history_index + 1) % FRAME_HISTORY_SIZE;
        self.frame_count += 1;
        self.fps_frame_count += 1;
        if (self.fps_sample_start_ns == 0) {
            self.fps_sample_start_ns = now;
        } else {
            const elapsed = now - self.fps_sample_start_ns;
            if (elapsed >= FPS_SAMPLE_INTERVAL_NS) {
                self.current_fps = @as(f32, @floatFromInt(self.fps_frame_count)) /
                    (@as(f32, @floatFromInt(elapsed)) / 1_000_000_000.0);
                self.fps_sample_start_ns = now;
                self.fps_frame_count = 0;
            }
        }
    }

    pub fn getAverageFrameTimeMs(self: *const Self) f32 {
        const count = @min(self.frame_count, FRAME_HISTORY_SIZE);
        if (count == 0) return 0.0;
        var total: u64 = 0;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            total += self.frame_history[i].frame_time_ns;
        }
        return @as(f32, @floatFromInt(total)) / @as(f32, @floatFromInt(count)) / 1_000_000.0;
    }

    pub fn handleClick(self: *Self, layout_id: ?u32) void {
        if (self.mode == .disabled) return;
        if (self.selected_layout_id != null and self.selected_layout_id == layout_id) {
            self.selected_layout_id = null;
            self.selected_element_info = .{};
        } else {
            self.selected_layout_id = layout_id;
        }
    }

    pub fn isToggleShortcut(key: KeyCode, mods: Modifiers) bool {
        if (key != .i or !mods.shift) return false;
        return mods.cmd or mods.ctrl;
    }

    pub fn updateSelectedElementInfo(self: *Self, layout: anytype) void {
        if (self.selected_layout_id == null) {
            self.selected_element_info.valid = false;
            return;
        }
        const layout_id = self.selected_layout_id.?;
        const index = layout.id_to_index.get(layout_id) orelse {
            self.selected_element_info.valid = false;
            return;
        };
        const elem = layout.elements.getConst(index);
        var info = &self.selected_element_info;
        info.layout_id = layout_id;
        info.element_type = elem.element_type;
        info.valid = true;
        info.x = elem.computed.bounding_box.x;
        info.y = elem.computed.bounding_box.y;
        info.width = elem.computed.bounding_box.width;
        info.height = elem.computed.bounding_box.height;
        info.content_x = elem.computed.content_box.x;
        info.content_y = elem.computed.content_box.y;
        info.content_width = elem.computed.content_box.width;
        info.content_height = elem.computed.content_box.height;
        const sizing = elem.config.layout.sizing;
        info.width_sizing = sizing.width.value;
        info.height_sizing = sizing.height.value;
        info.width_min = sizing.width.getMin();
        info.width_max = sizing.width.getMax();
        info.height_min = sizing.height.getMin();
        info.height_max = sizing.height.getMax();
        const padding = elem.config.layout.padding;
        info.padding_left = padding.left;
        info.padding_right = padding.right;
        info.padding_top = padding.top;
        info.padding_bottom = padding.bottom;
        info.child_gap = elem.config.layout.child_gap;
        info.child_count = elem.child_count;
        info.layout_direction = elem.config.layout.layout_direction;
        info.z_index = elem.cached_z_index;
        info.is_floating = elem.config.floating != null;
        info.source_location = elem.config.source_location;
        if (elem.text_data) |td| {
            const len = @min(td.text.len, info.text_preview.len - 1);
            @memcpy(info.text_preview[0..len], td.text[0..len]);
            info.text_preview_len = len;
        } else {
            info.text_preview_len = 0;
        }
    }

    pub fn generateOverlays(
        self: *Self,
        hovered_layout_id: ?u32,
        hovered_ancestors: []const u32,
        layout: anytype,
    ) void {
        if (self.mode == .disabled) return;
        self.overlay_count = 0;
        self.fmt_buffer_index = 0;
        self.updateSelectedElementInfo(layout);

        // Use raw hover ID directly - debouncing caused inconsistency with ancestors
        // since ancestors are computed for current frame's hover, not debounced hover
        if (hovered_layout_id != null) {
            for (hovered_ancestors) |ancestor_id| {
                if (ancestor_id == hovered_layout_id.?) continue;
                if (self.selected_layout_id != null and ancestor_id == self.selected_layout_id.?) continue;
                if (layout.getBoundingBox(ancestor_id)) |bounds| {
                    self.addBoundsOverlay(bounds, COLOR_ANCESTOR, COLOR_ANCESTOR_BORDER);
                }
            }
        }
        if (hovered_layout_id) |hovered_id| {
            if (self.selected_layout_id == null or hovered_id != self.selected_layout_id.?) {
                if (layout.getBoundingBox(hovered_id)) |bounds| {
                    self.addBoundsOverlay(bounds, COLOR_HOVER, COLOR_HOVER_BORDER);
                }
            }
        }
        if (self.selected_layout_id) |selected_id| {
            if (layout.getBoundingBox(selected_id)) |bounds| {
                self.addBoundsOverlay(bounds, COLOR_SELECTED, COLOR_SELECTED_BORDER);
            }
        }
    }

    fn addBoundsOverlay(self: *Self, bounds: BoundingBox, fill: Hsla, border: Hsla) void {
        if (self.overlay_count >= MAX_DEBUG_QUADS) return;
        std.debug.assert(bounds.width >= 0);
        std.debug.assert(bounds.height >= 0);
        self.overlay_quads[self.overlay_count] = .{
            .bounds_origin_x = bounds.x,
            .bounds_origin_y = bounds.y,
            .bounds_size_width = bounds.width,
            .bounds_size_height = bounds.height,
            .background = fill,
            .border_color = border,
            .border_widths = .{ .left = BORDER_WIDTH, .right = BORDER_WIDTH, .top = BORDER_WIDTH, .bottom = BORDER_WIDTH },
        };
        self.overlay_count += 1;
    }

    pub fn renderOverlays(self: *Self, s: *Scene) !void {
        if (self.mode == .disabled) return;
        if (self.overlay_count == 0) return;
        for (self.overlay_quads[0..self.overlay_count]) |quad| {
            try s.insertQuad(quad);
        }
    }

    pub fn modeName(self: *const Self) []const u8 {
        return switch (self.mode) {
            .disabled => "Off",
            .inspector_panel => "Inspector",
            .profiler => "Profiler",
        };
    }

    // =========================================================================
    // Format Helpers
    // =========================================================================

    fn fmtFloat(self: *Self, value: f32) []const u8 {
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        const result = std.fmt.bufPrint(buffer, "{d:.1}", .{value}) catch "?";
        return result;
    }

    fn fmtInt(self: *Self, value: anytype) []const u8 {
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        const result = std.fmt.bufPrint(buffer, "{d}", .{value}) catch "?";
        return result;
    }

    fn fmtHex(self: *Self, value: u32) []const u8 {
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        const result = std.fmt.bufPrint(buffer, "0x{X:0>8}", .{value}) catch "?";
        return result;
    }

    fn fmtBounds(self: *Self, x: f32, y: f32, w: f32, h: f32) []const u8 {
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        const result = std.fmt.bufPrint(buffer, "{d:.0},{d:.0} {d:.0}x{d:.0}", .{ x, y, w, h }) catch "?";
        return result;
    }

    fn fmtSizing(self: *Self, sizing: SizingType, min_val: f32, max_val: f32) []const u8 {
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        const type_str = switch (sizing) {
            .fit => "fit",
            .grow => "grow",
            .fixed => "fixed",
            .percent => "percent",
        };
        const has_min = min_val > 0;
        const has_max = max_val < std.math.floatMax(f32);
        if (has_min and has_max) {
            const result = std.fmt.bufPrint(buffer, "{s} ({d:.0}-{d:.0})", .{ type_str, min_val, max_val }) catch "?";
            return result;
        } else if (has_min) {
            const result = std.fmt.bufPrint(buffer, "{s} (>={d:.0})", .{ type_str, min_val }) catch "?";
            return result;
        } else if (has_max) {
            const result = std.fmt.bufPrint(buffer, "{s} (<={d:.0})", .{ type_str, max_val }) catch "?";
            return result;
        } else {
            return type_str;
        }
    }

    fn fmtPadding(self: *Self, top: u16, right: u16, bottom: u16, left: u16) []const u8 {
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        if (top == right and right == bottom and bottom == left) {
            if (top == 0) return "none";
            const result = std.fmt.bufPrint(buffer, "{d}", .{top}) catch "?";
            return result;
        }
        const result = std.fmt.bufPrint(buffer, "{d} {d} {d} {d}", .{ top, right, bottom, left }) catch "?";
        return result;
    }

    fn fmtSourceLoc(self: *Self, loc: SourceLoc) []const u8 {
        if (!loc.isValid()) return "(not tracked)";
        const buffer = &self.fmt_buffers[self.fmt_buffer_index];
        self.fmt_buffer_index = (self.fmt_buffer_index + 1) % FMT_BUFFER_COUNT;
        const basename = loc.getBasename() orelse "?";
        const result = std.fmt.bufPrint(buffer, "{s}:{d}", .{ basename, loc.line }) catch "?";
        return result;
    }

    fn elementTypeName(elem_type: ElementType) []const u8 {
        return switch (elem_type) {
            .container => "Container",
            .text => "Text",
            .svg => "SVG",
            .image => "Image",
        };
    }

    fn directionName(dir: LayoutDirection) []const u8 {
        return switch (dir) {
            .left_to_right => "Row",
            .top_to_bottom => "Column",
        };
    }

    // =========================================================================
    // Panel Rendering
    // =========================================================================

    pub fn renderProfilerPanel(
        self: *Self,
        s: *Scene,
        text_renderer: anytype,
        window_width: f32,
        scale_factor: f32,
    ) !void {
        if (self.mode != .profiler) return;
        const metrics = text_renderer.getMetrics() orelse return;
        const panel_x = window_width - PROFILER_WIDTH - PANEL_MARGIN;
        const panel_y = PANEL_MARGIN;

        var bg_quad = Quad.filled(panel_x, panel_y, PROFILER_WIDTH, PROFILER_HEIGHT, PANEL_BACKGROUND);
        bg_quad.border_color = PANEL_BORDER;
        bg_quad.border_widths = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 };
        bg_quad.corner_radii = .{ .top_left = 8, .top_right = 8, .bottom_left = 8, .bottom_right = 8 };
        try s.insertQuad(bg_quad);

        const x_left = panel_x + PANEL_PADDING;
        const row_height: f32 = 20;
        var row: f32 = 0;

        const fps_color = if (self.current_fps >= 55) COLOR_GOOD_FPS else if (self.current_fps >= 30) COLOR_OK_FPS else COLOR_BAD_FPS;
        const y0 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, self.fmtFloat(self.current_fps), x_left, y0, fps_color, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, " FPS", x_left + 50, y0, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        const frame_ms = @as(f32, @floatFromInt(self.frame_time_ns)) / 1_000_000.0;
        const y1 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Frame:", x_left, y1, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(frame_ms), x_left + 60, y1, COLOR_FRAME_TIME, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, y1, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        // --- CPU-side breakdown ---
        const tree_build_ms = @as(f32, @floatFromInt(self.tree_build_ns)) / 1_000_000.0;
        const yt = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Build:", x_left, yt, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(tree_build_ms), x_left + 60, yt, COLOR_TREE_BUILD, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, yt, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        const layout_ms = @as(f32, @floatFromInt(self.layout_time_ns)) / 1_000_000.0;
        const y2 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Layout:", x_left, y2, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(layout_ms), x_left + 60, y2, COLOR_LAYOUT_TIME, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, y2, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        const dispatch_ms = @as(f32, @floatFromInt(self.dispatch_sync_ns)) / 1_000_000.0;
        const yd = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Dispatch:", x_left, yd, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(dispatch_ms), x_left + 60, yd, COLOR_DISPATCH_SYNC, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, yd, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        const render_ms = @as(f32, @floatFromInt(self.render_time_ns)) / 1_000_000.0;
        const y3 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Render:", x_left, y3, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(render_ms), x_left + 60, y3, COLOR_RENDER_TIME, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, y3, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        // --- GPU-side (previous frame) ---
        const atlas_ms = @as(f32, @floatFromInt(self.atlas_upload_ns)) / 1_000_000.0;
        const ya = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Atlas:", x_left, ya, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(atlas_ms), x_left + 60, ya, COLOR_ATLAS_UPLOAD, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, ya, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        const gpu_ms = @as(f32, @floatFromInt(self.gpu_submit_ns)) / 1_000_000.0;
        const yg = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "GPU:", x_left, yg, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(gpu_ms), x_left + 60, yg, COLOR_GPU_SUBMIT, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 110, yg, TEXT_SECONDARY, scale_factor, metrics);
        row += 1;

        const last_snapshot = self.frame_history[(self.frame_history_index + FRAME_HISTORY_SIZE - 1) % FRAME_HISTORY_SIZE];
        const y4 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Quads:", x_left, y4, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtInt(last_snapshot.quads_rendered), x_left + 60, y4, TEXT_VALUE, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "Glyphs:", x_left + 120, y4, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtInt(last_snapshot.glyphs_rendered), x_left + 180, y4, TEXT_VALUE, scale_factor, metrics);
        row += 1;

        // Text shaping stats - key for debugging text performance
        const shape_time_ms = @as(f32, @floatFromInt(last_snapshot.shape_time_ns)) / 1_000_000.0;
        const shape_color = if (shape_time_ms > 5.0) COLOR_BAD_FPS else if (shape_time_ms > 2.0) COLOR_OK_FPS else TEXT_VALUE;
        const cache_color = if (last_snapshot.shape_cache_hits > 0) COLOR_GOOD_FPS else TEXT_VALUE;
        const y5 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_renderer, "Shape:", x_left, y5, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtInt(last_snapshot.shape_misses), x_left + 60, y5, shape_color, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "/", x_left + 90, y5, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtInt(last_snapshot.shape_cache_hits), x_left + 100, y5, cache_color, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "hit", x_left + 135, y5, TEXT_SECONDARY, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, self.fmtFloat(shape_time_ms), x_left + 165, y5, shape_color, scale_factor, metrics);
        try renderTextSimple(s, text_renderer, "ms", x_left + 215, y5, TEXT_SECONDARY, scale_factor, metrics);
        row += 1.5;

        const graph_y = panel_y + PANEL_PADDING + row * row_height;
        const graph_width = PROFILER_WIDTH - PANEL_PADDING * 2;

        const graph_bg = Quad.filled(x_left, graph_y, graph_width, GRAPH_HEIGHT, Hsla.init(0.0, 0.0, 0.05, 0.8));
        try s.insertQuad(graph_bg);

        const target_16ms_y = graph_y + GRAPH_HEIGHT - (16.67 / 33.33) * GRAPH_HEIGHT;
        const target_line = Quad.filled(x_left, target_16ms_y, graph_width, 1, COLOR_TARGET_LINE);
        try s.insertQuad(target_line);

        const bar_count = @min(self.frame_count, FRAME_HISTORY_SIZE);
        const bar_spacing: f32 = graph_width / @as(f32, @floatFromInt(FRAME_HISTORY_SIZE));

        var i: u32 = 0;
        while (i < bar_count) : (i += 1) {
            const idx = (self.frame_history_index + FRAME_HISTORY_SIZE - bar_count + i) % FRAME_HISTORY_SIZE;
            const snapshot = self.frame_history[idx];
            const frame_time_ms_bar = @as(f32, @floatFromInt(snapshot.frame_time_ns)) / 1_000_000.0;
            const bar_height = @min(frame_time_ms_bar / 33.33 * GRAPH_HEIGHT, GRAPH_HEIGHT);
            const bar_x = x_left + @as(f32, @floatFromInt(i)) * bar_spacing;
            const bar_y = graph_y + GRAPH_HEIGHT - bar_height;
            const bar_color = if (frame_time_ms_bar <= 16.67) COLOR_GOOD_FPS else if (frame_time_ms_bar <= 33.33) COLOR_OK_FPS else COLOR_BAD_FPS;
            const bar = Quad.filled(bar_x, bar_y, @max(bar_spacing - 1, 2), bar_height, bar_color);
            try s.insertQuad(bar);
        }
    }

    pub fn renderInspectorPanel(self: *Self, s: *Scene, text_system: anytype, viewport_width: f32, _: f32, scale_factor: f32) !void {
        if (self.mode != .inspector_panel) return;
        const metrics = text_system.getMetrics() orelse return;
        const row_height: f32 = 24;
        const panel_x = viewport_width - PANEL_WIDTH - PANEL_MARGIN;
        const panel_y = PANEL_MARGIN;
        const panel_height: f32 = PANEL_PADDING * 2 + row_height * 9;

        var panel_quad = Quad.filled(panel_x, panel_y, PANEL_WIDTH, panel_height, PANEL_BACKGROUND);
        panel_quad.border_color = PANEL_BORDER;
        panel_quad.border_widths = .{ .left = 1, .right = 1, .top = 1, .bottom = 1 };
        panel_quad.corner_radii = .{ .top_left = 8, .top_right = 8, .bottom_left = 8, .bottom_right = 8 };
        try s.insertQuad(panel_quad);

        const x_left = panel_x + PANEL_PADDING;
        const x_right = panel_x + PANEL_PADDING + 80;
        var row: f32 = 0;

        const y0 = panel_y + PANEL_PADDING + row * row_height;
        try renderTextSimple(s, text_system, "Inspector", x_left, y0, TEXT_PRIMARY, scale_factor, metrics);
        row += 1;

        if (self.selected_element_info.valid) {
            const info = &self.selected_element_info;

            const y1 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Type:", x_left, y1, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, elementTypeName(info.element_type), x_right, y1, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y2 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "ID:", x_left, y2, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, self.fmtHex(info.layout_id), x_right, y2, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y3 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Pos:", x_left, y3, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, self.fmtBounds(info.x, info.y, info.width, info.height), x_right, y3, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y4 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Width:", x_left, y4, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, self.fmtSizing(info.width_sizing, info.width_min, info.width_max), x_right, y4, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y5 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Height:", x_left, y5, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, self.fmtSizing(info.height_sizing, info.height_min, info.height_max), x_right, y5, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y6 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Dir:", x_left, y6, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, directionName(info.layout_direction), x_right, y6, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y7 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Children:", x_left, y7, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, self.fmtInt(info.child_count), x_right, y7, TEXT_VALUE, scale_factor, metrics);
            row += 1;

            const y8 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Source:", x_left, y8, TEXT_SECONDARY, scale_factor, metrics);
            try renderTextSimple(s, text_system, self.fmtSourceLoc(info.source_location), x_right, y8, TEXT_LABEL, scale_factor, metrics);
        } else {
            const y1 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "No element selected", x_left, y1, TEXT_SECONDARY, scale_factor, metrics);
            row += 1;
            const y2 = panel_y + PANEL_PADDING + row * row_height;
            try renderTextSimple(s, text_system, "Click to inspect", x_left, y2, TEXT_SECONDARY, scale_factor, metrics);
        }
    }
};

fn renderTextSimple(
    s: *Scene,
    text_system: anytype,
    content: []const u8,
    x: f32,
    y: f32,
    color: Hsla,
    scale_factor: f32,
    metrics: anytype,
) !void {
    if (content.len == 0) return;
    const baseline_y = y + metrics.ascender;
    var opts = text_render.RenderTextOptions{ .clipped = false };
    _ = text_render.renderText(s, text_system, content, x, baseline_y, scale_factor, color, metrics.point_size, &opts) catch return;
}

// =============================================================================
// Tests
// =============================================================================

test "debugger toggle cycles modes" {
    var dbg = Debugger{};
    try std.testing.expectEqual(DebugMode.disabled, dbg.mode);
    dbg.toggle();
    try std.testing.expectEqual(DebugMode.inspector_panel, dbg.mode);
    dbg.toggle();
    try std.testing.expectEqual(DebugMode.profiler, dbg.mode);
    dbg.toggle();
    try std.testing.expectEqual(DebugMode.disabled, dbg.mode);
}

test "debugger shortcut detection" {
    try std.testing.expect(Debugger.isToggleShortcut(.i, .{ .shift = true, .cmd = true }));
    try std.testing.expect(Debugger.isToggleShortcut(.i, .{ .shift = true, .ctrl = true }));
    try std.testing.expect(!Debugger.isToggleShortcut(.i, .{}));
    try std.testing.expect(!Debugger.isToggleShortcut(.i, .{ .shift = true }));
    try std.testing.expect(!Debugger.isToggleShortcut(.j, .{ .shift = true, .cmd = true }));
}

test "debugger click selection" {
    var dbg = Debugger{};
    dbg.mode = .inspector_panel;
    try std.testing.expectEqual(@as(?u32, null), dbg.selected_layout_id);
    dbg.handleClick(42);
    try std.testing.expectEqual(@as(?u32, 42), dbg.selected_layout_id);
    dbg.handleClick(42);
    try std.testing.expectEqual(@as(?u32, null), dbg.selected_layout_id);
    dbg.handleClick(42);
    dbg.handleClick(100);
    try std.testing.expectEqual(@as(?u32, 100), dbg.selected_layout_id);
}

test "debugger disabled mode skips generation" {
    const dbg = Debugger{};
    try std.testing.expectEqual(@as(u32, 0), dbg.overlay_count);
}

test "debugger isActive" {
    var dbg = Debugger{};
    try std.testing.expect(!dbg.isActive());
    dbg.mode = .inspector_panel;
    try std.testing.expect(dbg.isActive());
    dbg.mode = .profiler;
    try std.testing.expect(dbg.isActive());
    dbg.mode = .disabled;
    try std.testing.expect(!dbg.isActive());
}

test "debugger showInspector" {
    var dbg = Debugger{};
    try std.testing.expect(!dbg.showInspector());
    dbg.mode = .inspector_panel;
    try std.testing.expect(dbg.showInspector());
    dbg.mode = .profiler;
    try std.testing.expect(!dbg.showInspector());
}

test "debugger format helpers" {
    var dbg = Debugger{};
    const float_result = dbg.fmtFloat(123.456);
    try std.testing.expectEqualStrings("123.5", float_result);
    const int_result = dbg.fmtInt(@as(u32, 42));
    try std.testing.expectEqualStrings("42", int_result);
    const hex_result = dbg.fmtHex(0xDEADBEEF);
    try std.testing.expectEqualStrings("0xDEADBEEF", hex_result);
    const pad_same = dbg.fmtPadding(8, 8, 8, 8);
    try std.testing.expectEqualStrings("8", pad_same);
    const pad_zero = dbg.fmtPadding(0, 0, 0, 0);
    try std.testing.expectEqualStrings("none", pad_zero);
    const pad_diff = dbg.fmtPadding(1, 2, 3, 4);
    try std.testing.expectEqualStrings("1 2 3 4", pad_diff);
}

test "debugger sizing format" {
    var dbg = Debugger{};
    const fit_plain = dbg.fmtSizing(.fit, 0, std.math.floatMax(f32));
    try std.testing.expectEqualStrings("fit", fit_plain);
    const grow_min = dbg.fmtSizing(.grow, 100, std.math.floatMax(f32));
    try std.testing.expect(std.mem.startsWith(u8, grow_min, "grow (>=100"));
    const fixed_max = dbg.fmtSizing(.fixed, 0, 200);
    try std.testing.expect(std.mem.startsWith(u8, fixed_max, "fixed (<=200"));
}

test "element info defaults" {
    const info = ElementInfo{};
    try std.testing.expect(!info.valid);
    try std.testing.expectEqual(ElementType.container, info.element_type);
    try std.testing.expectEqual(@as(f32, 0), info.x);
    try std.testing.expectEqual(@as(usize, 0), info.text_preview_len);
}

test "element type names" {
    try std.testing.expectEqualStrings("Container", Debugger.elementTypeName(.container));
    try std.testing.expectEqualStrings("Text", Debugger.elementTypeName(.text));
    try std.testing.expectEqualStrings("SVG", Debugger.elementTypeName(.svg));
    try std.testing.expectEqualStrings("Image", Debugger.elementTypeName(.image));
}

test "direction names" {
    try std.testing.expectEqualStrings("Row", Debugger.directionName(.left_to_right));
    try std.testing.expectEqualStrings("Column", Debugger.directionName(.top_to_bottom));
}

test "profiler timing" {
    var debugger = Debugger{};
    debugger.mode = .profiler;
    debugger.frame_time_ns = 16_000_000;
    debugger.layout_time_ns = 2_000_000;
    debugger.render_time_ns = 10_000_000;
    debugger.endFrame(null);
    try std.testing.expect(debugger.frame_count == 1);
    const snapshot = debugger.frame_history[0];
    try std.testing.expectEqual(@as(u64, 16_000_000), snapshot.frame_time_ns);
}

test "fmtSourceLoc returns placeholder for invalid location" {
    var debugger = Debugger{};
    const loc = SourceLoc.none;
    const formatted = debugger.fmtSourceLoc(loc);
    try std.testing.expectEqualStrings("(not tracked)", formatted);
}
