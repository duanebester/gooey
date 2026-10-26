//! Disk Tree MVP — bounded, read-only disk usage explorer.
//!
//! Run with `zig build run-disktree -- [directory]`. The directory is scanned
//! before the event loop starts; all runtime navigation reuses fixed storage.

const std = @import("std");
const gooey = @import("gooey");
const platform = gooey.platform;
const ui = gooey.ui;
const Cx = gooey.Cx;

// Resource sketch: initialization performs at most 16,384 directory-entry
// stats, keeps at most 32 directory handles open, and stores at most 8,192
// nodes (~1.2 MiB). A frame lays out and paints at most 256 tiles. Bitmap text
// emits at most 3 × 5 quads per displayed character and never enters Gooey's
// allocating text shaper. Network and texture-upload work are zero.
const node_count_max: u32 = 8_192;
const scan_depth_max: u32 = 32;
const child_count_max: u32 = 256;
const entry_count_max: u32 = 16_384;
const tile_count_max: u32 = child_count_max;
const name_bytes_max: u32 = 127;
const path_bytes_max: u32 = 1_024;
const index_none = std.math.maxInt(u32);
const bitmap_quads_character_max: u32 = 15;
const tile_label_character_count_max: u32 = 12;
const fixed_text_character_count_max: u32 = 432;
const frame_shape_quad_count_max: u32 = tile_count_max * 6 + 20;
const frame_quad_count_max: u32 =
    (fixed_text_character_count_max + tile_count_max * (tile_label_character_count_max + 1)) *
    bitmap_quads_character_max + frame_shape_quad_count_max;

// The tile map can emit up to 57,956 quads in one frame, above `.large`, so this
// app declares the framework ceiling as its budget and proves the bound against
// exactly the budget it declares.
const resource_limits = gooey.ResourceLimits.ceiling;

comptime {
    std.debug.assert(frame_quad_count_max <= resource_limits.scene.quad_count_frame_max);
}

const map_x: f32 = 20;
const map_y: f32 = 104;
const panel_width: f32 = 286;
const content_gap: f32 = 12;
const footer_height: f32 = 36;
const canvas_id = "disktree-canvas";

const Palette = struct {
    const background = ui.Color.hex(0x11131b);
    const surface = ui.Color.hex(0x181b27);
    const surface_raised = ui.Color.hex(0x202536);
    const border = ui.Color.hex(0x343b52);
    const text = ui.Color.hex(0xd9def5);
    const muted = ui.Color.hex(0x858da8);
    const accent = ui.Color.hex(0x7aa2f7);
    const warning = ui.Color.hex(0xe0af68);
    const tiles = [_]ui.Color{
        ui.Color.hex(0x293b5f),
        ui.Color.hex(0x3d3156),
        ui.Color.hex(0x294a47),
        ui.Color.hex(0x4d3a31),
        ui.Color.hex(0x344b36),
        ui.Color.hex(0x4c3041),
        ui.Color.hex(0x41452d),
        ui.Color.hex(0x303b50),
    };
};

const Node = struct {
    bytes: u64 = 0,
    file_count: u32 = 0,
    child_count: u16 = 0,
    parent: u32 = index_none,
    first_child: u32 = index_none,
    next_sibling: u32 = index_none,
    name_len: u8 = 0,
    is_directory: bool = false,
    unreadable: bool = false,
    name: [name_bytes_max]u8 = undefined,

    fn label(self: *const Node) []const u8 {
        std.debug.assert(self.name_len <= name_bytes_max);
        return self.name[0..self.name_len];
    }
};

const Tile = struct {
    node: u32 = index_none,
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,
};

const ScanFrame = struct {
    node: u32,
    directory: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
};

var scan_stack: [scan_depth_max]ScanFrame = undefined;

const State = struct {
    nodes: [node_count_max]Node = undefined,
    tiles: [tile_count_max]Tile = undefined,
    root_path: [path_bytes_max]u8 = undefined,
    node_count: u32 = 0,
    tile_count: u32 = 0,
    root_path_len: u16 = 0,
    current: u32 = 0,
    selected: u32 = 0,
    scanned_entry_count: u32 = 0,
    unreadable_count: u32 = 0,

    const InitError = error{
        ChildCapacityExceeded,
        EmptyRootPath,
        EntryBudgetExceeded,
        NodeCapacityExceeded,
        RootPathTooLong,
        ScanDepthExceeded,
        SizeOverflow,
    };

    noinline fn init(self: *State, io: std.Io, root_path: []const u8) !void {
        try validate_root_path(root_path);
        self.node_count = 0;
        self.tile_count = 0;
        self.root_path_len = 0;
        self.current = 0;
        self.selected = 0;
        self.scanned_entry_count = 0;
        self.unreadable_count = 0;
        @memset(&self.root_path, 0);
        self.root_path_len = @intCast(encode_display(root_path, &self.root_path));
        _ = try self.add_node(index_none, root_path, true);
        try self.scan(io, root_path);
        self.current = 0;
        self.selected = 0;
        std.debug.assert(self.node_count > 0);
    }

    fn scan(self: *State, io: std.Io, root_path: []const u8) !void {
        const root = try std.Io.Dir.cwd().openDir(io, root_path, .{
            .iterate = true,
            .follow_symlinks = false,
        });
        scan_stack[0] = .{ .node = 0, .directory = root, .iterator = root.iterate() };
        var depth: u32 = 1;
        defer close_open_directories(io, &depth);
        while (depth > 0) {
            std.debug.assert(depth <= scan_depth_max);
            if (try self.scan_next(io, &depth)) continue;
            const frame = &scan_stack[depth - 1];
            try self.finish_directory(frame.node);
            frame.directory.close(io);
            depth -= 1;
        }
        std.debug.assert(self.nodes[0].is_directory);
    }

    fn scan_next(self: *State, io: std.Io, depth: *u32) !bool {
        std.debug.assert(depth.* > 0);
        std.debug.assert(depth.* <= scan_depth_max);
        const frame = &scan_stack[depth.* - 1];
        const entry = (try frame.iterator.next(io)) orelse return false;
        if (self.scanned_entry_count == entry_count_max) {
            return error.EntryBudgetExceeded;
        }
        self.scanned_entry_count += 1;
        const stat = frame.directory.statFile(io, entry.name, .{
            .follow_symlinks = false,
        }) catch {
            self.unreadable_count += 1;
            return true;
        };
        if (stat.kind == .sym_link) return true;
        const is_directory = stat.kind == .directory;
        const child = try self.add_node(frame.node, entry.name, is_directory);
        if (is_directory) {
            self.scan_directory_child(io, frame, child, entry.name, depth);
        } else {
            self.nodes[child].bytes = stat.size;
            self.nodes[child].file_count = 1;
        }
        return true;
    }

    fn scan_directory_child(
        self: *State,
        io: std.Io,
        parent: *ScanFrame,
        child: u32,
        name: []const u8,
        depth: *u32,
    ) void {
        std.debug.assert(self.nodes[child].is_directory);
        std.debug.assert(depth.* < scan_depth_max);
        const directory = parent.directory.openDir(io, name, .{
            .iterate = true,
            .follow_symlinks = false,
        }) catch {
            self.nodes[child].unreadable = true;
            self.unreadable_count += 1;
            return;
        };
        scan_stack[depth.*] = .{
            .node = child,
            .directory = directory,
            .iterator = directory.iterate(),
        };
        depth.* += 1;
        std.debug.assert(depth.* <= scan_depth_max);
    }

    fn finish_directory(self: *State, node_index: u32) InitError!void {
        std.debug.assert(node_index < self.node_count);
        std.debug.assert(self.nodes[node_index].is_directory);
        var child = self.nodes[node_index].first_child;
        var child_count: u32 = 0;
        while (child != index_none) : (child = self.nodes[child].next_sibling) {
            std.debug.assert(child < self.node_count);
            const sum = @addWithOverflow(
                self.nodes[node_index].bytes,
                self.nodes[child].bytes,
            );
            if (sum[1] != 0) return error.SizeOverflow;
            self.nodes[node_index].bytes = sum[0];
            self.nodes[node_index].file_count += self.nodes[child].file_count;
            child_count += 1;
            std.debug.assert(child_count <= node_count_max);
        }
    }

    fn add_node(self: *State, parent: u32, name: []const u8, is_directory: bool) InitError!u32 {
        std.debug.assert(name.len > 0);
        if (self.node_count == node_count_max) return error.NodeCapacityExceeded;
        if (is_directory and parent != index_none) {
            if (self.node_depth(parent) + 1 > scan_depth_max) {
                return error.ScanDepthExceeded;
            }
        }
        if (parent != index_none) {
            if (self.nodes[parent].child_count == child_count_max) {
                return error.ChildCapacityExceeded;
            }
        }
        const index = self.node_count;
        self.nodes[index] = .{ .parent = parent, .is_directory = is_directory };
        @memset(&self.nodes[index].name, 0);
        self.nodes[index].name_len = @intCast(encode_display(name, &self.nodes[index].name));
        self.node_count += 1;
        if (parent != index_none) {
            std.debug.assert(parent < index);
            self.nodes[index].next_sibling = self.nodes[parent].first_child;
            self.nodes[parent].first_child = index;
            self.nodes[parent].child_count += 1;
        }
        return index;
    }

    fn node_depth(self: *const State, start: u32) u32 {
        std.debug.assert(start < self.node_count);
        var depth: u32 = 0;
        var node = start;
        while (node != index_none) : (depth += 1) {
            std.debug.assert(depth < scan_depth_max);
            node = self.nodes[node].parent;
        }
        return depth;
    }

    fn select(self: *State, node: u32) void {
        std.debug.assert(node < self.node_count);
        self.selected = node;
        std.debug.assert(self.selected < self.node_count);
    }

    fn open_selected(self: *State) void {
        std.debug.assert(self.selected < self.node_count);
        if (!self.nodes[self.selected].is_directory) return;
        self.current = self.selected;
        std.debug.assert(self.nodes[self.current].is_directory);
    }

    fn go_up(self: *State) void {
        std.debug.assert(self.current < self.node_count);
        const parent = self.nodes[self.current].parent;
        if (parent == index_none) return;
        self.current = parent;
        self.selected = parent;
    }

    fn root_path_label(self: *const State) []const u8 {
        std.debug.assert(self.root_path_len <= path_bytes_max);
        return self.root_path[0..self.root_path_len];
    }
};

fn validate_root_path(root_path: []const u8) State.InitError!void {
    if (root_path.len == 0) return error.EmptyRootPath;
    if (root_path.len > path_bytes_max) return error.RootPathTooLong;
}

var state = State{};

const App = gooey.App(State, &state, render, .{
    .title = "Disk Tree — Gooey MVP",
    .width = 1180,
    .height = 760,
    .on_init = on_init,
    .on_event = on_event,
    .limits = resource_limits,
});

comptime {
    std.debug.assert(@sizeOf(State) < 2 * 1024 * 1024);
    _ = App;
}

pub fn main(init: std.process.Init) !void {
    if (platform.is_wasm) unreachable;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.skip();
    const root_path = if (args.next()) |argument| argument else ".";
    state.init(init.io, root_path) catch |err| {
        std.log.err(
            "disk scan failed: {s} (path bytes {d}, nodes {d}, children {d}, entries {d})",
            .{ @errorName(err), root_path.len, node_count_max, child_count_max, entry_count_max },
        );
        return err;
    };
    return App.main(init);
}

fn render(cx: *Cx) void {
    const size = cx.windowSize();
    var canvas = ui.canvasWithData(size.width, size.height, paint_app, &state);
    canvas.id = canvas_id;
    cx.render(canvas);
}

fn on_init(cx: *Cx) void {
    cx.reserve_canvas(.{
        .canvas_count = 1,
        .quad_count = frame_quad_count_max,
    }) catch @panic("disk tree canvas reservation failed");
}

fn paint_app(ctx: *ui.DrawContext) void {
    const s: *State = @ptrCast(@alignCast(ctx.user_data.?));
    const map_width = @max(ctx.width() - 40 - panel_width - content_gap, 240);
    const map_height = @max(ctx.height() - map_y - footer_height - 20, 220);
    layout_tiles(s, map_width, map_height);
    ctx.fillRect(0, 0, ctx.width(), ctx.height(), Palette.background);
    paint_header(ctx, s);
    paint_summary(ctx, s);
    ctx.fillRoundedRect(map_x, map_y, map_width, map_height, 6, Palette.surface);
    paint_tiles(ctx, s);
    paint_details(ctx, s, map_width, map_height);
    paint_footer(ctx, s);
}

fn paint_header(ctx: *ui.DrawContext, s: *const State) void {
    var path_buffer: [path_bytes_max + 32]u8 = undefined;
    const path = current_path(s, &path_buffer);
    ctx.fillRoundedRect(20, 22, 18, 18, 3, Palette.accent);
    draw_bitmap_text(ctx, "DISK TREE", 48, 22, 3, Palette.text, 20);
    draw_bitmap_text(ctx, path, 180, 26, 2, Palette.muted, 70);
    const up_x = ctx.width() - 146;
    const open_x = ctx.width() - 82;
    ctx.fillRoundedRect(up_x, 18, 54, 28, 4, Palette.surface_raised);
    ctx.strokeRect(up_x, 18, 54, 28, Palette.border, 1);
    draw_bitmap_text(ctx, "UP", up_x + 18, 27, 2, Palette.text, 2);
    ctx.fillRoundedRect(open_x, 18, 62, 28, 4, Palette.accent);
    draw_bitmap_text(ctx, "OPEN", open_x + 14, 27, 2, Palette.background, 4);
}

fn paint_summary(ctx: *ui.DrawContext, s: *const State) void {
    var bytes_buffer: [32]u8 = undefined;
    var stats_buffer: [128]u8 = undefined;
    const root = &s.nodes[0];
    const bytes = format_bytes(root.bytes, &bytes_buffer);
    const stats = std.fmt.bufPrint(&stats_buffer, "{s} APPARENT  {d} FILES  {d} NODES", .{
        bytes,
        root.file_count,
        s.node_count,
    }) catch "SCAN SUMMARY UNAVAILABLE";
    ctx.fillRoundedRect(20, 62, ctx.width() - 40, 30, 4, Palette.surface);
    ctx.strokeRect(20, 62, ctx.width() - 40, 30, Palette.border, 1);
    draw_bitmap_text(ctx, stats, 30, 72, 2, Palette.muted, 100);
}

fn paint_tiles(ctx: *ui.DrawContext, s: *const State) void {
    std.debug.assert(s.tile_count <= tile_count_max);
    for (s.tiles[0..s.tile_count], 0..) |tile, color_index| {
        const node = &s.nodes[tile.node];
        const selected = tile.node == s.selected;
        const inset: f32 = 2;
        const color = Palette.tiles[color_index % Palette.tiles.len];
        if (tile.width <= 4 or tile.height <= 4) continue;
        ctx.fillRect(
            map_x + tile.x + inset,
            map_y + tile.y + inset,
            tile.width - 4,
            tile.height - 4,
            color,
        );
        const accent = if (selected) Palette.accent else color;
        ctx.fillRect(map_x + tile.x + inset, map_y + tile.y + inset, tile.width - 4, 3, accent);
        if (selected) {
            ctx.strokeRect(
                map_x + tile.x + 1,
                map_y + tile.y + 1,
                tile.width - 2,
                tile.height - 2,
                Palette.accent,
                2,
            );
        }
        if (tile.width > 74 and tile.height > 34) {
            const width_character_count: u32 = @intFromFloat(@max((tile.width - 18) / 8, 1));
            const character_count = @min(width_character_count, tile_label_character_count_max);
            draw_bitmap_text(
                ctx,
                node.label(),
                map_x + tile.x + 9,
                map_y + tile.y + 10,
                2,
                Palette.text,
                character_count,
            );
        }
        if (node.unreadable and tile.width > 42) {
            draw_bitmap_text(
                ctx,
                "!",
                map_x + tile.x + tile.width - 16,
                map_y + tile.y + 8,
                2,
                Palette.warning,
                1,
            );
        }
    }
}

fn paint_details(
    ctx: *ui.DrawContext,
    s: *const State,
    map_width: f32,
    map_height: f32,
) void {
    const x = map_x + map_width + content_gap;
    const selected = &s.nodes[s.selected];
    var bytes_buffer: [32]u8 = undefined;
    var count_buffer: [64]u8 = undefined;
    const bytes = format_bytes(selected.bytes, &bytes_buffer);
    const counts = std.fmt.bufPrint(&count_buffer, "{d} FILES", .{selected.file_count}) catch "";
    ctx.fillRoundedRect(x, map_y, panel_width, map_height, 6, Palette.surface);
    ctx.strokeRect(x, map_y, panel_width, map_height, Palette.border, 1);
    draw_bitmap_text(ctx, "SELECTION", x + 18, map_y + 20, 2, Palette.muted, 9);
    draw_bitmap_text(ctx, selected.label(), x + 18, map_y + 44, 3, Palette.text, 20);
    const kind = if (selected.is_directory) "DIRECTORY" else "FILE";
    draw_bitmap_text(ctx, kind, x + 18, map_y + 68, 2, Palette.accent, 9);
    ctx.fillRect(x + 18, map_y + 91, panel_width - 36, 1, Palette.border);
    draw_bitmap_text(ctx, bytes, x + 18, map_y + 112, 4, Palette.text, 16);
    draw_bitmap_text(ctx, "APPARENT SIZE", x + 18, map_y + 142, 2, Palette.muted, 13);
    draw_bitmap_text(ctx, counts, x + 18, map_y + 166, 2, Palette.text, 20);
    if (selected.unreadable) {
        draw_bitmap_text(ctx, "CONTENTS UNREADABLE", x + 18, map_y + 190, 2, Palette.warning, 20);
    }
    draw_bitmap_text(ctx, "READ-ONLY MVP", x + 18, map_y + map_height - 70, 2, Palette.muted, 13);
    draw_bitmap_text(
        ctx,
        "CLICK TO INSPECT",
        x + 18,
        map_y + map_height - 46,
        2,
        Palette.muted,
        20,
    );
    draw_bitmap_text(
        ctx,
        "DOUBLE-CLICK TO OPEN",
        x + 18,
        map_y + map_height - 26,
        2,
        Palette.muted,
        22,
    );
}

fn paint_footer(ctx: *ui.DrawContext, s: *const State) void {
    var status_buffer: [96]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "{d} UNREADABLE  {d} ENTRIES", .{
        s.unreadable_count,
        s.scanned_entry_count,
    }) catch "";
    const y = ctx.height() - 22;
    draw_bitmap_text(ctx, "CLICK SELECT  ENTER OPEN  ESC UP", 20, y, 2, Palette.muted, 40);
    draw_bitmap_text(ctx, status, ctx.width() - 270, y, 2, Palette.muted, 34);
}

fn layout_tiles(s: *State, width: f32, height: f32) void {
    std.debug.assert(s.current < s.node_count);
    std.debug.assert(width > 0 and height > 0);
    var indices: [tile_count_max]u32 = undefined;
    var count: u32 = 0;
    var child = s.nodes[s.current].first_child;
    while (child != index_none and count < tile_count_max) : (child = s.nodes[child].next_sibling) {
        indices[count] = child;
        count += 1;
    }
    sort_nodes_by_size(s, indices[0..count]);
    s.tile_count = count;
    if (count == 0) return;
    layout_binary(s, indices[0..count], width, height);
}

const LayoutTask = struct { start: u32, end: u32, x: f32, y: f32, width: f32, height: f32 };

fn layout_binary(s: *State, indices: []const u32, width: f32, height: f32) void {
    var tasks: [tile_count_max]LayoutTask = undefined;
    var task_count: u32 = 1;
    tasks[0] = .{
        .start = 0,
        .end = @intCast(indices.len),
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    };
    while (task_count > 0) {
        task_count -= 1;
        const task = tasks[task_count];
        if (task.end - task.start == 1) {
            s.tiles[task.start] = .{
                .node = indices[task.start],
                .x = task.x,
                .y = task.y,
                .width = task.width,
                .height = task.height,
            };
            continue;
        }
        const split = layout_split(s, indices, task.start, task.end);
        const ratio = layout_ratio(s, indices, task.start, split, task.end);
        std.debug.assert(task_count + 2 <= tile_count_max);
        if (task.width >= task.height) {
            const first_width = task.width * ratio;
            tasks[task_count] = .{
                .start = task.start,
                .end = split,
                .x = task.x,
                .y = task.y,
                .width = first_width,
                .height = task.height,
            };
            tasks[task_count + 1] = .{
                .start = split,
                .end = task.end,
                .x = task.x + first_width,
                .y = task.y,
                .width = task.width - first_width,
                .height = task.height,
            };
        } else {
            const first_height = task.height * ratio;
            tasks[task_count] = .{
                .start = task.start,
                .end = split,
                .x = task.x,
                .y = task.y,
                .width = task.width,
                .height = first_height,
            };
            tasks[task_count + 1] = .{
                .start = split,
                .end = task.end,
                .x = task.x,
                .y = task.y + first_height,
                .width = task.width,
                .height = task.height - first_height,
            };
        }
        task_count += 2;
    }
}

fn layout_split(s: *const State, indices: []const u32, start: u32, end: u32) u32 {
    std.debug.assert(start < end);
    var total: u128 = 0;
    for (indices[start..end]) |index| total += @max(s.nodes[index].bytes, 1);
    var first: u128 = 0;
    var split = start + 1;
    while (split < end) : (split += 1) {
        const next = first + @max(s.nodes[indices[split - 1]].bytes, 1);
        if (next >= total - next) break;
        first = next;
    }
    return split;
}

fn layout_ratio(s: *const State, indices: []const u32, start: u32, split: u32, end: u32) f32 {
    std.debug.assert(start < split);
    std.debug.assert(split < end);
    var first: u128 = 0;
    var total: u128 = 0;
    for (indices[start..end], start..) |index, position| {
        const bytes = @max(s.nodes[index].bytes, 1);
        total += bytes;
        if (position < split) first += bytes;
    }
    return @as(f32, @floatFromInt(first)) / @as(f32, @floatFromInt(total));
}

fn sort_nodes_by_size(s: *const State, indices: []u32) void {
    var i: usize = 1;
    while (i < indices.len) : (i += 1) {
        var j = i;
        while (j > 0 and s.nodes[indices[j]].bytes > s.nodes[indices[j - 1]].bytes) : (j -= 1) {
            std.mem.swap(u32, &indices[j], &indices[j - 1]);
        }
    }
}

fn on_event(cx: *Cx, event: gooey.input.InputEvent) bool {
    if (event == .mouse_down and event.mouse_down.button == .left) {
        const point = event.mouse_down.position;
        const bounds = cx.window().getBounds(cx.idFor(canvas_id)) orelse return false;
        const x: f32 = @floatCast(point.x - bounds.x);
        const y: f32 = @floatCast(point.y - bounds.y);
        if (!bounds.contains(@floatCast(point.x), @floatCast(point.y))) return false;
        if (y >= 18 and y < 46 and x >= bounds.width - 146) {
            if (x < bounds.width - 92) state.go_up() else state.open_selected();
            cx.notify();
            return true;
        }
        const node = hit_test(&state, x - map_x, y - map_y);
        if (node) |index| {
            state.select(index);
            if (event.mouse_down.click_count >= 2) state.open_selected();
            cx.notify();
            return true;
        }
    }
    if (event == .key_down) {
        const key = event.key_down.key;
        if (key == .@"return") {
            state.open_selected();
        } else {
            if (key == .escape or key == .delete) {
                state.go_up();
            } else {
                return false;
            }
        }
        cx.notify();
        return true;
    }
    return false;
}

fn hit_test(s: *const State, x: f32, y: f32) ?u32 {
    std.debug.assert(s.tile_count <= tile_count_max);
    if (x < 0 or y < 0) return null;
    for (s.tiles[0..s.tile_count]) |tile| {
        if (x >= tile.x and x < tile.x + tile.width) {
            if (y >= tile.y and y < tile.y + tile.height) return tile.node;
        }
    }
    return null;
}

fn format_bytes(bytes: u64, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= 16);
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value = @as(f64, @floatFromInt(bytes));
    var unit: u32 = 0;
    while (value >= 1024 and unit + 1 < units.len) : (unit += 1) value /= 1024;
    if (unit == 0) return std.fmt.bufPrint(buffer, "{d:.0} {s}", .{
        value,
        units[unit],
    }) catch "?";
    return std.fmt.bufPrint(buffer, "{d:.1} {s}", .{ value, units[unit] }) catch "?";
}

fn current_path(s: *const State, buffer: []u8) []const u8 {
    std.debug.assert(s.current < s.node_count);
    var chain: [scan_depth_max]u32 = undefined;
    var count: u32 = 0;
    var node = s.current;
    while (node != index_none and count < scan_depth_max) : (count += 1) {
        chain[count] = node;
        node = s.nodes[node].parent;
    }
    var stream = std.Io.Writer.fixed(buffer);
    var index = count;
    while (index > 0) {
        index -= 1;
        if (index + 1 == count) {
            stream.writeAll(s.root_path_label()) catch return "path too long";
        } else {
            stream.writeAll(" / ") catch return "path too long";
            stream.writeAll(s.nodes[chain[index]].label()) catch return "path too long";
        }
    }
    return stream.buffered();
}

fn close_open_directories(io: std.Io, depth: *u32) void {
    std.debug.assert(depth.* <= scan_depth_max);
    while (depth.* > 0) {
        scan_stack[depth.* - 1].directory.close(io);
        depth.* -= 1;
    }
    std.debug.assert(depth.* == 0);
}

const IteratorFailureIo = struct {
    backing: std.Io,
    vtable: std.Io.VTable,
    opened: [2]std.Io.Dir = undefined,
    close_counts: [2]u8 = .{ 0, 0 },
    open_count: u8 = 0,

    fn init(backing: std.Io) IteratorFailureIo {
        var self = IteratorFailureIo{ .backing = backing, .vtable = backing.vtable.* };
        self.vtable.dirOpenDir = open_dir;
        self.vtable.dirStatFile = stat_file;
        self.vtable.dirClose = close_dir;
        self.vtable.dirRead = read_dir;
        return self;
    }

    fn io(self: *IteratorFailureIo) std.Io {
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    fn get(userdata: ?*anyopaque) *IteratorFailureIo {
        return @ptrCast(@alignCast(userdata.?));
    }

    fn open_dir(
        userdata: ?*anyopaque,
        directory: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.OpenOptions,
    ) std.Io.Dir.OpenError!std.Io.Dir {
        const self = get(userdata);
        const opened = try self.backing.vtable.dirOpenDir(
            self.backing.userdata,
            directory,
            path,
            options,
        );
        std.debug.assert(self.open_count < self.opened.len);
        self.opened[self.open_count] = opened;
        self.open_count += 1;
        return opened;
    }

    fn stat_file(
        userdata: ?*anyopaque,
        directory: std.Io.Dir,
        path: []const u8,
        options: std.Io.Dir.StatFileOptions,
    ) std.Io.Dir.StatFileError!std.Io.File.Stat {
        const self = get(userdata);
        return self.backing.vtable.dirStatFile(self.backing.userdata, directory, path, options);
    }

    fn close_dir(userdata: ?*anyopaque, directories: []const std.Io.Dir) void {
        const self = get(userdata);
        for (directories) |directory| {
            var index: u8 = 0;
            while (index < self.open_count) : (index += 1) {
                if (directory.handle != self.opened[index].handle) continue;
                self.close_counts[index] += 1;
                break;
            }
            std.debug.assert(index < self.open_count);
        }
        self.backing.vtable.dirClose(self.backing.userdata, directories);
    }

    fn read_dir(
        userdata: ?*anyopaque,
        reader: *std.Io.Dir.Reader,
        entries: []std.Io.Dir.Entry,
    ) std.Io.Dir.Reader.Error!usize {
        const self = get(userdata);
        if (self.open_count == 2) {
            if (reader.dir.handle == self.opened[1].handle) return error.Unexpected;
        }
        return self.backing.vtable.dirRead(self.backing.userdata, reader, entries);
    }
};

const CountingAllocator = struct {
    backing: std.mem.Allocator,
    call_count: u32 = 0,

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = allocate,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn allocate(
        context: *anyopaque,
        length: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.call_count += 1;
        return self.backing.rawAlloc(length, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.call_count += 1;
        return self.backing.rawResize(memory, alignment, new_length, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_length: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.call_count += 1;
        return self.backing.rawRemap(memory, alignment, new_length, return_address);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(context));
        self.call_count += 1;
        self.backing.rawFree(memory, alignment, return_address);
    }
};

fn paint_test_frame(
    window: *gooey.Window,
    builder: *ui.Builder,
    test_state: *State,
    options: struct { width: f32, height: f32 },
) void {
    builder.pending_canvas.clearRetainingCapacity();
    builder.registerPendingCanvas(.{
        .layout_id = 1,
        .paint = paint_app,
        .scale = 1,
        .user_data = test_state,
    });
    var draw_context = ui.DrawContext{
        .scene = window.next_frame.scene,
        .bounds = gooey.scene.Bounds.init(0, 0, options.width, options.height),
        .scale = 1,
        .base_order = 1,
        .user_data = test_state,
    };
    paint_app(&draw_context);
    window.next_frame.scene.finish();
}

fn encode_display(input: []const u8, output: []u8) usize {
    std.debug.assert(output.len > 0);
    var written: usize = 0;
    for (input, 0..) |byte, input_index| {
        const plain = byte >= 0x20 and byte <= 0x7e and byte != '\\';
        const needed: usize = if (plain) 1 else 4;
        const marker_needed: usize = if (input_index + 1 < input.len) 1 else 0;
        if (needed + marker_needed > output.len - written) {
            if (written < output.len) {
                output[written] = '~';
                return written + 1;
            }
            return output.len;
        }
        if (plain) {
            output[written] = byte;
            written += 1;
        } else {
            output[written..][0..2].* = "\\x".*;
            output[written + 2] = hex_digit(byte >> 4);
            output[written + 3] = hex_digit(byte & 0x0f);
            written += 4;
        }
    }
    return written;
}

fn hex_digit(value: u8) u8 {
    std.debug.assert(value < 16);
    return if (value < 10) '0' + value else 'A' + value - 10;
}

fn draw_bitmap_text(
    ctx: *ui.DrawContext,
    text: []const u8,
    x: f32,
    y: f32,
    scale: f32,
    color: ui.Color,
    character_count_max: u32,
) void {
    std.debug.assert(scale > 0);
    std.debug.assert(character_count_max <= path_bytes_max + 32);
    const count = @min(text.len, character_count_max);
    for (text[0..count], 0..) |character, character_index| {
        const rows = bitmap_glyph(character);
        for (rows, 0..) |row, row_index| {
            var column: u2 = 0;
            while (column < 3) : (column += 1) {
                const mask = @as(u3, 0b100) >> column;
                if (row & mask == 0) continue;
                const glyph_x = @as(f32, @floatFromInt(character_index * 4));
                const pixel_x = @as(f32, @floatFromInt(column));
                const pixel_y = @as(f32, @floatFromInt(row_index));
                ctx.fillRect(
                    x + (glyph_x + pixel_x) * scale,
                    y + pixel_y * scale,
                    scale,
                    scale,
                    color,
                );
            }
        }
    }
}

fn bitmap_glyph(character_raw: u8) [5]u3 {
    const character = std.ascii.toUpper(character_raw);
    return switch (character) {
        'A' => .{ 0b010, 0b101, 0b111, 0b101, 0b101 },
        'B' => .{ 0b110, 0b101, 0b110, 0b101, 0b110 },
        'C' => .{ 0b011, 0b100, 0b100, 0b100, 0b011 },
        'D' => .{ 0b110, 0b101, 0b101, 0b101, 0b110 },
        'E' => .{ 0b111, 0b100, 0b110, 0b100, 0b111 },
        'F' => .{ 0b111, 0b100, 0b110, 0b100, 0b100 },
        'G' => .{ 0b011, 0b100, 0b101, 0b101, 0b011 },
        'H' => .{ 0b101, 0b101, 0b111, 0b101, 0b101 },
        'I' => .{ 0b111, 0b010, 0b010, 0b010, 0b111 },
        'J' => .{ 0b001, 0b001, 0b001, 0b101, 0b010 },
        'K' => .{ 0b101, 0b101, 0b110, 0b101, 0b101 },
        'L' => .{ 0b100, 0b100, 0b100, 0b100, 0b111 },
        'M' => .{ 0b101, 0b111, 0b111, 0b101, 0b101 },
        'N' => .{ 0b101, 0b111, 0b111, 0b111, 0b101 },
        'O' => .{ 0b010, 0b101, 0b101, 0b101, 0b010 },
        'P' => .{ 0b110, 0b101, 0b110, 0b100, 0b100 },
        'Q' => .{ 0b010, 0b101, 0b101, 0b111, 0b011 },
        'R' => .{ 0b110, 0b101, 0b110, 0b101, 0b101 },
        'S' => .{ 0b011, 0b100, 0b010, 0b001, 0b110 },
        'T' => .{ 0b111, 0b010, 0b010, 0b010, 0b010 },
        'U' => .{ 0b101, 0b101, 0b101, 0b101, 0b111 },
        'V' => .{ 0b101, 0b101, 0b101, 0b101, 0b010 },
        'W' => .{ 0b101, 0b101, 0b111, 0b111, 0b101 },
        'X' => .{ 0b101, 0b101, 0b010, 0b101, 0b101 },
        'Y' => .{ 0b101, 0b101, 0b010, 0b010, 0b010 },
        'Z' => .{ 0b111, 0b001, 0b010, 0b100, 0b111 },
        '0' => .{ 0b111, 0b101, 0b101, 0b101, 0b111 },
        '1' => .{ 0b010, 0b110, 0b010, 0b010, 0b111 },
        '2' => .{ 0b110, 0b001, 0b010, 0b100, 0b111 },
        '3' => .{ 0b110, 0b001, 0b010, 0b001, 0b110 },
        '4' => .{ 0b101, 0b101, 0b111, 0b001, 0b001 },
        '5' => .{ 0b111, 0b100, 0b110, 0b001, 0b110 },
        '6' => .{ 0b011, 0b100, 0b110, 0b101, 0b010 },
        '7' => .{ 0b111, 0b001, 0b010, 0b010, 0b010 },
        '8' => .{ 0b010, 0b101, 0b010, 0b101, 0b010 },
        '9' => .{ 0b010, 0b101, 0b011, 0b001, 0b110 },
        '.' => .{ 0, 0, 0, 0, 0b010 },
        '-' => .{ 0, 0, 0b111, 0, 0 },
        '_' => .{ 0, 0, 0, 0, 0b111 },
        '/' => .{ 0b001, 0b001, 0b010, 0b100, 0b100 },
        '\\' => .{ 0b100, 0b100, 0b010, 0b001, 0b001 },
        ':' => .{ 0, 0b010, 0, 0b010, 0 },
        '!' => .{ 0b010, 0b010, 0b010, 0, 0b010 },
        '~' => .{ 0, 0b010, 0b101, 0, 0 },
        ' ' => .{ 0, 0, 0, 0, 0 },
        else => .{ 0b110, 0b001, 0b010, 0, 0b010 },
    };
}

test "binary treemap fills its bounds and hit testing selects both sides" {
    // Asymmetric sizes catch an accidental equal split or reversed ratio.
    var test_state = State{};
    _ = try test_state.add_node(index_none, "root", true);
    const large = try test_state.add_node(0, "large", false);
    const small = try test_state.add_node(0, "small", false);
    test_state.nodes[large].bytes = 3;
    test_state.nodes[small].bytes = 1;
    layout_tiles(&test_state, 400, 200);
    try std.testing.expectEqual(@as(u32, 2), test_state.tile_count);
    try std.testing.expectEqual(large, test_state.tiles[0].node);
    try std.testing.expectApproxEqAbs(@as(f32, 300), test_state.tiles[0].width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 100), test_state.tiles[1].width, 0.01);
    try std.testing.expectEqual(large, hit_test(&test_state, 250, 100).?);
    try std.testing.expectEqual(small, hit_test(&test_state, 350, 100).?);
    try std.testing.expectEqual(null, hit_test(&test_state, 400, 100));
}

test "opening and ascending preserve directory navigation" {
    var test_state = State{};
    _ = try test_state.add_node(index_none, "root", true);
    const directory = try test_state.add_node(0, "directory", true);
    test_state.selected = directory;
    test_state.open_selected();
    try std.testing.expectEqual(directory, test_state.current);
    test_state.go_up();
    try std.testing.expectEqual(@as(u32, 0), test_state.current);
    try std.testing.expectEqual(@as(u32, 0), test_state.selected);
}

test "node arena accepts its final slot and rejects one more node" {
    // Fill every slot through the public boundary so initialization is covered.
    var test_state = State{};
    var index: u32 = 0;
    while (index < node_count_max) : (index += 1) {
        try std.testing.expectEqual(index, try test_state.add_node(index_none, "node", false));
    }
    try std.testing.expectEqual(node_count_max, test_state.node_count);
    try std.testing.expectError(
        error.NodeCapacityExceeded,
        test_state.add_node(index_none, "overflow", false),
    );
}

test "directory child and depth capacities fail at exact boundaries" {
    var test_state = State{};
    const root = try test_state.add_node(index_none, "root", true);
    var child_index: u32 = 0;
    while (child_index < child_count_max) : (child_index += 1) {
        _ = try test_state.add_node(root, "file", false);
    }
    try std.testing.expectError(
        error.ChildCapacityExceeded,
        test_state.add_node(root, "overflow", false),
    );

    var depth_state = State{};
    var parent = try depth_state.add_node(index_none, "root", true);
    var depth: u32 = 1;
    while (depth < scan_depth_max) : (depth += 1) {
        parent = try depth_state.add_node(parent, "directory", true);
    }
    const node_count_before = depth_state.node_count;
    try std.testing.expectError(
        error.ScanDepthExceeded,
        depth_state.add_node(parent, "overflow", true),
    );
    try std.testing.expectEqual(node_count_before, depth_state.node_count);
}

test "display encoding escapes invalid bytes without partial escapes" {
    var output: [9]u8 = undefined;
    const encoded_len = encode_display("a\xff€z", &output);
    try std.testing.expectEqualStrings("a\\xFF~", output[0..encoded_len]);

    var exact: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), encode_display("\xff", &exact));
    try std.testing.expectEqualStrings("\\xFF", &exact);
}

test "root path validation covers both capacity boundaries" {
    var maximum: [path_bytes_max]u8 = @splat('a');
    try std.testing.expectError(error.EmptyRootPath, validate_root_path(""));
    try validate_root_path("a");
    try validate_root_path(&maximum);
    try std.testing.expectError(
        error.RootPathTooLong,
        validate_root_path(&@as([path_bytes_max + 1]u8, @splat('a'))),
    );
}

test "layout handles portrait bounds and maximum weights" {
    var test_state = State{};
    _ = try test_state.add_node(index_none, "root", true);
    const first = try test_state.add_node(0, "first", false);
    const second = try test_state.add_node(0, "second", false);
    test_state.nodes[first].bytes = std.math.maxInt(u64);
    test_state.nodes[second].bytes = std.math.maxInt(u64);
    layout_tiles(&test_state, 200, 400);
    try std.testing.expectApproxEqAbs(@as(f32, 200), test_state.tiles[0].height, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 200), test_state.tiles[1].height, 0.01);
    try std.testing.expectEqual(test_state.tiles[0].node, hit_test(&test_state, 100, 100).?);
    try std.testing.expectEqual(test_state.tiles[1].node, hit_test(&test_state, 100, 300).?);
    try std.testing.expect(test_state.tiles[0].node != test_state.tiles[1].node);
}

test "directory byte aggregation returns overflow" {
    var test_state = State{};
    const root = try test_state.add_node(index_none, "root", true);
    const first = try test_state.add_node(root, "first", false);
    const second = try test_state.add_node(root, "second", false);
    test_state.nodes[first].bytes = std.math.maxInt(u64);
    test_state.nodes[second].bytes = 1;
    try std.testing.expectError(error.SizeOverflow, test_state.finish_directory(root));
}

test "scanner aggregates files and never follows directory symlinks" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "real", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "real/data",
        .data = "abc",
    });
    try temporary.dir.symLink(std.testing.io, "real", "link", .{ .is_directory = true });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);

    var test_state = State{};
    try test_state.init(std.testing.io, path_buffer[0..path_len]);
    try std.testing.expectEqual(@as(u64, 3), test_state.nodes[0].bytes);
    try std.testing.expectEqual(@as(u32, 1), test_state.nodes[0].file_count);
    try std.testing.expectEqual(@as(u32, 3), test_state.node_count);
    try std.testing.expectEqual(@as(u32, 3), test_state.scanned_entry_count);
}

test "scanner closes every directory after an iterator error below root" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "child", .default_dir);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try temporary.dir.realPath(std.testing.io, &path_buffer);

    var failing_io = IteratorFailureIo.init(std.testing.io);
    var test_state = State{};
    _ = try test_state.add_node(index_none, "root", true);
    try std.testing.expectError(
        error.Unexpected,
        test_state.scan(failing_io.io(), path_buffer[0..path_len]),
    );
    try std.testing.expectEqual(@as(u8, 2), failing_io.open_count);
    try std.testing.expectEqual([_]u8{ 1, 1 }, failing_io.close_counts);
}

test "reserved canvas paints navigation and resize without allocation" {
    var counting = CountingAllocator{ .backing = std.testing.allocator };
    const allocator = counting.allocator();
    var scene_a = try gooey.scene.Scene.initCapacity(allocator, &resource_limits.scene);
    defer scene_a.deinit();
    var scene_b = try gooey.scene.Scene.initCapacity(allocator, &resource_limits.scene);
    defer scene_b.deinit();
    var dispatch_a = gooey.context.DispatchTree.init(allocator);
    defer dispatch_a.deinit();
    var dispatch_b = gooey.context.DispatchTree.init(allocator);
    defer dispatch_b.deinit();
    var layout = gooey.layout.LayoutEngine.init(allocator);
    defer layout.deinit();
    var builder = ui.Builder.init(allocator, &layout, &scene_a, &dispatch_a);
    defer builder.deinit();
    var window: gooey.Window = undefined;
    window.next_frame = gooey.context.Frame.borrowed(allocator, &scene_a, &dispatch_a);
    window.rendered_frame = gooey.context.Frame.borrowed(allocator, &scene_b, &dispatch_b);
    var context = Cx{
        ._allocator = allocator,
        ._window = &window,
        ._builder = &builder,
        .state_ptr = undefined,
        .state_type_id = 0,
    };
    on_init(&context);

    var test_state = State{};
    const root = try test_state.add_node(index_none, "root", true);
    const directory = try test_state.add_node(root, "directory", true);
    const file = try test_state.add_node(directory, "file", false);
    test_state.nodes[file].bytes = 100;
    test_state.nodes[file].file_count = 1;
    try test_state.finish_directory(directory);
    try test_state.finish_directory(root);
    test_state.current = root;
    test_state.selected = directory;

    counting.call_count = 0;
    paint_test_frame(&window, &builder, &test_state, .{ .width = 1_180, .height = 760 });
    std.mem.swap(@TypeOf(window.next_frame), &window.next_frame, &window.rendered_frame);
    test_state.open_selected();
    paint_test_frame(&window, &builder, &test_state, .{ .width = 4_096, .height = 2_304 });
    try std.testing.expect(window.next_frame.scene.quads.items.len <= frame_quad_count_max);
    try std.testing.expectEqual(@as(u32, 0), counting.call_count);
}
