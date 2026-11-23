const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");
const vopr = @import("vopr.zig");

const assert = std.debug.assert;

const ui = gooey.ui;
const Cx = gooey.Cx;
const Button = components.Button;
const internals = gooey.internals;
const records = internals.records;
const Window = internals.window.Window;
const Action = vopr.Action;

pub const path_count: u32 = 8;
pub const page_count: u32 = 4;
pub const slot_count: u32 = 4;

pub const paths = [path_count][]const u8{
    "vopr/image-0.png", "vopr/image-1.png", "vopr/image-2.png", "vopr/image-3.png",
    "vopr/image-4.png", "vopr/image-5.png", "vopr/image-6.png", "vopr/image-7.png",
};

pub const Slot = struct {
    width: f32,
    height: f32,
    fit: ui.ObjectFit,
    color: ui.Color,
};

pub const slots = [slot_count]Slot{
    .{ .width = 64, .height = 64, .fit = .contain, .color = ui.Color.hex(0x123456) },
    .{ .width = 120, .height = 40, .fit = .contain, .color = ui.Color.hex(0x234567) },
    .{ .width = 40, .height = 90, .fit = .fill, .color = ui.Color.hex(0x345678) },
    .{ .width = 75, .height = 50, .fit = .fill, .color = ui.Color.hex(0x456789) },
};

pub fn pathIndex(page: u32, slot: u32) u32 {
    assert(page < page_count);
    assert(slot < slot_count);
    return (2 * page + slot) % path_count;
}

const Cell = struct { path: []const u8, slot: *const Slot };

const cells: [page_count][slot_count]Cell = blk: {
    var table: [page_count][slot_count]Cell = undefined;
    for (0..page_count) |page| {
        for (0..slot_count) |slot| {
            table[page][slot] = .{ .path = paths[pathIndex(page, slot)], .slot = &slots[slot] };
        }
    }
    break :blk table;
};

pub const State = struct {
    page: u32 = 0,

    pub fn next(self: *State) void {
        assert(self.page < page_count);
        self.page = (self.page + 1) % page_count;
    }
};

pub const App = gooey.App(State, render, .{
    .title = "VOPR images",
    .width = 640,
    .height = 320,
    .limits = .small,
});

comptime {
    assert(App.limits.atlas.image_request_count_max == path_count);
    assert(App.limits.paint.image_count_frame_max >= slot_count);
}

fn render(cx: *Cx) void {
    const s = cx.state(State);
    assert(s.page < page_count);
    cx.render(ui.box(.{ .style = .{
        .width = .{ .grow = 1 },
        .height = .{ .grow = 1 },
        .padding = .all(16),
        .gap = 16,
    } }, .{
        Button{ .label = "Next page", .on_click = cx.on(State.next, .{}) },
        ui.box(.{ .style = .{ .direction = .row, .gap = 12 } }, .{Cells{ .page = s.page }}),
    }));
}

const Cells = struct {
    page: u32,

    pub fn render(self: Cells, cx: *Cx) void {
        assert(self.page < page_count);
        for (&cells[self.page]) |*cell| {
            cx.render(ui.paint(Cell, cell, paintCell, .{
                .width = .{ .fixed = cell.slot.width },
                .height = .{ .fixed = cell.slot.height },
            }));
        }
    }
};

fn paintCell(cell: *const Cell, painter: *ui.Painter) void {
    assert(cell.path.len > 0);
    assert(painter.bounds.width > 0);
    painter.fill(painter.bounds, cell.slot.color);
    painter.image(cell.path, painter.bounds, .{ .fit = cell.slot.fit });
}

const PathState = enum { idle, queued, delivered, cached, failed };

const Size = struct { width: u32, height: u32 };

const Delivered = struct { path: u32, decode: Action.ImageDecode };

pub const ImagesModel = struct {
    states: [path_count]PathState,
    sizes: [path_count]Size,
    requested_frame: [path_count]u64,
    fifo: [path_count]u32,
    fifo_head: u32,
    fifo_count: u32,
    pushed: ?Action.ImageDecode,
    delivered: ?Delivered,
    scale_factor_built: f32,
    counts: Stats,

    pub const action_kinds: []const vopr.ActionKind = &.{
        .pointer, .key, .wait_ns, .tick_main, .present, .resize, .image,
    };

    pub const key_choices: []const gooey.input.KeyCode = &.{
        .tab, .space, .@"return", .escape,
    };

    pub const image_sides: []const u32 = &.{ 1, 2, 30, 31, 60 };

    pub const Stats = struct {
        requests: u32,
        landed: u32,
        failed: u32,
        deferred: u32,
        scale_clears: u32,
        landed_offscreen: u32,
        builds_to_land_max: u64,
        queued_max: u32,
        drawn: u32,

        const zero: Stats = .{
            .requests = 0,
            .landed = 0,
            .failed = 0,
            .deferred = 0,
            .scale_clears = 0,
            .landed_offscreen = 0,
            .builds_to_land_max = 0,
            .queued_max = 0,
            .drawn = 0,
        };

        pub fn format(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            try writer.print("{d} requests, {d} landed ({d} off screen, up to {d} builds " ++
                "late), {d} failed, {d} deferred, {d} scale clears, {d} queued at most, " ++
                "{d} images drawn", .{
                self.requests,           self.landed,     self.landed_offscreen,
                self.builds_to_land_max, self.failed,     self.deferred,
                self.scale_clears,       self.queued_max, self.drawn,
            });
        }
    };

    pub fn init(self: *ImagesModel) void {
        self.states = @splat(.idle);
        self.sizes = @splat(.{ .width = 0, .height = 0 });
        self.requested_frame = @splat(0);
        self.fifo = @splat(0);
        self.fifo_head = 0;
        self.fifo_count = 0;
        self.pushed = null;
        self.delivered = null;
        self.scale_factor_built = 2;
        self.counts = .zero;
    }

    pub fn stats(self: *const ImagesModel) Stats {
        assert(self.fifo_count <= path_count);
        return self.counts;
    }

    pub fn pendingRoom(self: *const ImagesModel) u32 {
        assert(self.fifo_count <= path_count);
        return 1;
    }

    pub fn queue(self: *ImagesModel, action: Action) void {
        assert(action != .tick_main);
        switch (action) {
            .image => |decode| {
                assert(self.pushed == null);
                assert(self.delivered == null);
                self.pushed = decode;
            },
            else => {},
        }
    }

    pub fn beginDrain(self: *ImagesModel, window: *Window) void {
        const decode = self.pushed orelse return;
        self.pushed = null;
        const path = pathOfEntry(window, decode.entry);
        if (self.fifo_count == 0 or self.fifo[self.fifo_head] != path) {
            std.debug.panic("vopr images model: the loader handed out \"{s}\"; the oldest " ++
                "request is {s}", .{ paths[path], self.oldestName() });
        }
        assert(self.states[path] == .queued);
        self.fifo_head = (self.fifo_head + 1) % path_count;
        self.fifo_count -= 1;
        self.states[path] = .delivered;
        self.delivered = .{ .path = path, .decode = decode };
    }

    pub fn endDrain(self: *ImagesModel, window: *Window, published: bool) void {
        if (published) {
            const frame = window.built();
            if (frame.scale_factor != self.scale_factor_built) self.clearScale(frame.scale_factor);
            self.land(window, frame.frame_number);
            const app: *const App = @fieldParentPtr("window", window);
            const page = app.state.page;
            self.request(page, frame.frame_number);
            checkFrame(self, frame, page);
        }
        self.checkLoader(window);
    }

    pub fn check(self: *const ImagesModel, state: *const State, step: u64) void {
        assert(self.fifo_count <= path_count);
        if (state.page < page_count) return;
        std.debug.panic("vopr images model: page {d} after step {d}", .{ state.page, step });
    }

    pub fn biasTarget(window: *Window) ?vopr.Bias {
        const frame = window.rendered();
        for (frame.a11y[0..frame.a11y_count]) |*node| {
            if (node.role == .button) return .{ .area = node.bounds, .alternate = null };
        }
        return null;
    }

    fn clearScale(self: *ImagesModel, scale_factor: f32) void {
        assert(scale_factor > 0);
        var cleared = false;
        for (&self.states) |*state| {
            if (state.* == .cached) {
                state.* = .idle;
                cleared = true;
            }
        }
        if (cleared) self.counts.scale_clears += 1;
        self.scale_factor_built = scale_factor;
    }

    fn land(self: *ImagesModel, window: *Window, frame_number: u64) void {
        const delivered = self.delivered orelse return;
        if (window.images.landed != null) {
            self.counts.deferred += 1;
            return;
        }
        self.delivered = null;
        const path = delivered.path;
        assert(self.states[path] == .delivered);
        assert(frame_number >= self.requested_frame[path]);
        self.counts.builds_to_land_max = @max(
            self.counts.builds_to_land_max,
            frame_number - self.requested_frame[path],
        );
        if (delivered.decode.failure != null) {
            self.states[path] = .failed;
            self.counts.failed += 1;
            return;
        }
        self.states[path] = .cached;
        self.sizes[path] = .{ .width = delivered.decode.width, .height = delivered.decode.height };
        self.counts.landed += 1;
        const app: *const App = @fieldParentPtr("window", window);
        if (!onPage(app.state.page, path)) self.counts.landed_offscreen += 1;
    }

    fn request(self: *ImagesModel, page: u32, frame_number: u64) void {
        assert(page < page_count);
        for (0..slot_count) |slot| {
            const path = pathIndex(page, @intCast(slot));
            if (self.states[path] != .idle) continue;
            assert(self.fifo_count < path_count);
            self.fifo[(self.fifo_head + self.fifo_count) % path_count] = path;
            self.fifo_count += 1;
            self.states[path] = .queued;
            self.requested_frame[path] = frame_number;
            self.counts.requests += 1;
        }
        self.counts.queued_max = @max(self.counts.queued_max, self.fifo_count);
    }

    fn checkLoader(self: *const ImagesModel, window: *Window) void {
        const loader = &window.images;
        const tail = loader.request_tail.load(.monotonic);
        const queued = loader.request_head.load(.monotonic) -% tail;
        if (queued != self.fifo_count) {
            std.debug.panic("vopr images model: {d} requests queued; the model expects {d}", .{
                queued,
                self.fifo_count,
            });
        }
        const mask: u32 = @intCast(loader.requests.len - 1);
        for (0..self.fifo_count) |offset| {
            const entry = loader.requests[(tail +% @as(u32, @intCast(offset))) & mask];
            const expected = self.fifo[(self.fifo_head + offset) % path_count];
            const actual = pathOfEntry(window, entry);
            if (actual != expected) {
                std.debug.panic("vopr images model: request {d} is \"{s}\"; the model " ++
                    "expects \"{s}\"", .{ offset, paths[actual], paths[expected] });
            }
        }
        var pending: u32 = 0;
        var failed: u32 = 0;
        for (loader.entries) |*entry| {
            switch (entry.state) {
                .free => {},
                .pending => pending += 1,
                .failed => failed += 1,
            }
        }
        const delivered: u32 = if (self.delivered != null) 1 else 0;
        assert(self.pushed == null);
        assert(pending == self.fifo_count + delivered);
        assert(failed == self.countState(.failed));
    }

    fn countState(self: *const ImagesModel, state: PathState) u32 {
        var count: u32 = 0;
        for (self.states) |each| {
            if (each == state) count += 1;
        }
        assert(count <= path_count);
        return count;
    }

    fn oldestName(self: *const ImagesModel) []const u8 {
        if (self.fifo_count == 0) return "none";
        return paths[self.fifo[self.fifo_head]];
    }
};

fn onPage(page: u32, path: u32) bool {
    assert(path < path_count);
    for (0..slot_count) |slot| {
        if (pathIndex(page, @intCast(slot)) == path) return true;
    }
    return false;
}

fn pathOfEntry(window: *Window, entry_index: u32) u32 {
    const entry = &window.images.entries[entry_index];
    assert(entry.state != .free);
    for (paths, 0..) |path, index| {
        if (internals.images.keyFor(path).source_hash == entry.source_hash) {
            return @intCast(index);
        }
    }
    std.debug.panic("vopr images model: entry {d} holds no path of the app", .{entry_index});
}

fn checkFrame(model: *ImagesModel, frame: *const records.Frame, page: u32) void {
    var cell_found: [slot_count]bool = @splat(false);
    var cell_last: ?u32 = null;
    for (frame.paint[0..frame.paint_count]) |*record| {
        const cell = cell_last;
        cell_last = null;
        switch (record.*) {
            .quad => |*quad| if (slotOfQuad(quad)) |slot| {
                assert(!cell_found[slot]);
                cell_found[slot] = true;
                cell_last = slot;
            },
            .sprite => |*sprite| if (sprite.atlas == .image) {
                const slot = cell orelse std.debug.panic("vopr images model: an image " ++
                    "drawn outside every cell in frame {d}", .{frame.frame_number});
                checkSprite(model, frame, page, slot, sprite);
                model.counts.drawn += 1;
            },
            else => {},
        }
    }
    for (cell_found, 0..) |found, slot| {
        if (!found) std.debug.panic("vopr images model: cell {d} missing", .{slot});
    }
    checkDrawnCount(model, frame, page);
}

fn checkDrawnCount(model: *const ImagesModel, frame: *const records.Frame, page: u32) void {
    var expected: u32 = 0;
    for (0..slot_count) |slot| {
        if (model.states[pathIndex(page, @intCast(slot))] == .cached) expected += 1;
    }
    var drawn: u32 = 0;
    for (frame.paint[0..frame.paint_count]) |*record| {
        if (record.* == .sprite and record.sprite.atlas == .image) drawn += 1;
    }
    if (drawn == expected) return;
    std.debug.panic("vopr images model: frame {d} drew {d} images; page {d} shows {d} " ++
        "landed paths", .{ frame.frame_number, drawn, page, expected });
}

fn slotOfQuad(quad: *const records.Quad) ?u32 {
    for (slots, 0..) |slot, index| {
        const color = slot.color;
        if (quad.fill.r == color.r and quad.fill.g == color.g and quad.fill.b == color.b and
            quad.fill.a == color.a) return @intCast(index);
    }
    return null;
}

fn checkSprite(
    model: *const ImagesModel,
    frame: *const records.Frame,
    page: u32,
    slot: u32,
    sprite: *const records.Sprite,
) void {
    const path = pathIndex(page, slot);
    if (model.states[path] != .cached) {
        std.debug.panic("vopr images model: cell {d} drew \"{s}\", which is {t}, in " ++
            "frame {d}", .{ slot, paths[path], model.states[path], frame.frame_number });
    }
    const size = model.sizes[path];
    const atlas_size: f32 = @floatFromInt(App.limits.atlas.image_size);
    const width: f32 = @floatFromInt(size.width);
    const height: f32 = @floatFromInt(size.height);
    const cell = cellBounds(frame, slot);
    const placed = place(slots[slot].fit, cell, width, height);
    const pixel = 1 / frame.scale_factor;
    const tolerance = 0.01;
    const ok = near(sprite.uv.width * atlas_size, width, tolerance) and
        near(sprite.uv.height * atlas_size, height, tolerance) and
        near(sprite.bounds.width, placed.width, tolerance) and
        near(sprite.bounds.height, placed.height, tolerance) and
        snappedDown(sprite.bounds.x, placed.x, pixel) and
        snappedDown(sprite.bounds.y, placed.y, pixel);
    if (ok) return;
    std.debug.panic("vopr images model: cell {d} drew \"{s}\" ({d}x{d}) at ({d}, {d}) " ++
        "{d}x{d}, uv {d}x{d}; the model expects ({d}, {d}) {d}x{d}", .{
        slot,            paths[path],      size.width,          size.height,
        sprite.bounds.x, sprite.bounds.y,  sprite.bounds.width, sprite.bounds.height,
        sprite.uv.width, sprite.uv.height, placed.x,            placed.y,
        placed.width,    placed.height,
    });
}

fn cellBounds(frame: *const records.Frame, slot: u32) records.Rect {
    for (frame.paint[0..frame.paint_count]) |*record| {
        if (record.* != .quad) continue;
        if (slotOfQuad(&record.quad) == slot) return record.quad.bounds;
    }
    unreachable;
}

fn place(fit: ui.ObjectFit, cell: records.Rect, width: f32, height: f32) records.Rect {
    assert(width > 0);
    assert(height > 0);
    switch (fit) {
        .fill => return cell,
        .contain => {
            const scale = @min(cell.width / width, cell.height / height);
            const placed_width = width * scale;
            const placed_height = height * scale;
            return .{
                .x = cell.x + (cell.width - placed_width) / 2,
                .y = cell.y + (cell.height - placed_height) / 2,
                .width = placed_width,
                .height = placed_height,
            };
        },
        else => unreachable,
    }
}

fn snappedDown(actual: f32, expected: f32, pixel: f32) bool {
    assert(pixel > 0);
    const tolerance = 0.01;
    return actual <= expected + tolerance and actual > expected - pixel - tolerance;
}

fn near(actual: f32, expected: f32, tolerance: f32) bool {
    assert(tolerance > 0);
    return @abs(actual - expected) <= tolerance;
}
