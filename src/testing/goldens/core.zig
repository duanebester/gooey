//! Trace driver for the 0.4.0 core (`gooey.core`), the port's side of the
//! goldens.
//!
//! Input goes through the window's event queue, exactly as a platform pushes
//! it; each frame is one `tick`, which packs the frame and hands it to a
//! `NullRenderer` through the window's presenter. Hits and the accessibility
//! tree are read from the rendered frame, the one the router and `Query` use.

const std = @import("std");
const gooey = @import("gooey");
const counter = @import("core_counter_example");
const todo = @import("core_todo_example");
const trace_mod = @import("trace.zig");
const traces = @import("traces.zig");

const assert = std.debug.assert;

const core = gooey.core;
const testing = gooey.testing;
const TextBuffer = testing.record_dump.TextBuffer;
const NullRenderer = testing.NullRenderer;
const core_backend = core.backend;
const records = core.internals.records;
const Window = core.internals.window.Window;

/// One frame per 60 Hz refresh, so ticks see a moving clock.
const frame_interval_ns: u64 = 16_666_667;

pub fn CoreDriver(comptime App: type) type {
    return struct {
        app: App,
        renderer: NullRenderer,
        now_ns: u64,

        const Self = @This();

        pub fn deliver(self: *Self, event: gooey.input.InputEvent) void {
            self.app.window.queue.push(.{ .input = event });
        }

        pub fn frame(self: *Self) void {
            self.now_ns += frame_interval_ns;
            self.app.tick(self.now_ns);
            assert(self.renderer.draw_count > 0);
        }

        pub fn writeRecord(self: *const Self, out: *TextBuffer) void {
            out.print("{s}", .{self.renderer.frameDump()});
            out.print("hits\n", .{});
            writeHits(self.app.window.rendered(), out);
            out.print("a11y\n", .{});
            writeA11y(self.app.window.rendered(), out);
        }

        /// Initialize in place: the app and renderer must not move.
        pub fn initInPlace(
            self: *Self,
            allocator: std.mem.Allocator,
            io: std.Io,
            trace: *const trace_mod.Trace,
        ) !void {
            assert(trace.width == @as(f32, @floatFromInt(App.width)));
            assert(trace.height == @as(f32, @floatFromInt(App.height)));
            try self.app.initHeadless(allocator, io, .{ .scale_factor = trace.scale_factor });
            errdefer self.app.deinitHeadless();
            const render_limits = core_backend.RenderLimits.fromResourceLimits(&App.limits);
            const surface = core_backend.Surface{
                .native = null,
                .size_px = .{
                    .width = @intFromFloat(trace.width * trace.scale_factor),
                    .height = @intFromFloat(trace.height * trace.scale_factor),
                },
                .scale_factor = trace.scale_factor,
            };
            try self.renderer.initInPlace(&surface, &render_limits);
            const atlas = self.app.resources.text_system.getAtlas();
            self.renderer.observeGlyphAtlas(.{ .pixels = atlas.getData(), .size = atlas.size });
            self.app.window.presenter = .{ .context = &self.renderer, .draw = present };
            self.now_ns = 0;
        }

        pub fn deinit(self: *Self) void {
            self.app.stop();
            self.renderer.deinit();
            self.app.deinit();
        }
    };
}

fn present(
    context: *anyopaque,
    scene: *const core_backend.PackedFrame,
    frame: *const records.Frame,
    clear: records.Color,
) void {
    const renderer: *NullRenderer = @ptrCast(@alignCast(context));
    assert(frame.scale_factor > 0);
    renderer.draw(scene, .{
        .size_px = .{
            .width = @intFromFloat(frame.viewport_width * frame.scale_factor),
            .height = @intFromFloat(frame.viewport_height * frame.scale_factor),
        },
        .scale_factor = frame.scale_factor,
    }, clear);
}

/// Interactive hit records in tree order, in the 0.3.1 dump's format. Keyed
/// boxes without handlers or focus exist only for hover and are left out.
pub fn writeHits(frame: *const records.Frame, out: *TextBuffer) void {
    for (frame.hits[0..frame.hit_count]) |*record| {
        const click = record.on_click != records.index_none;
        const key = record.on_key != records.index_none;
        if (!click and !key and !record.focusable) continue;
        out.print("  hit {f}{s}{s}{s}\n", .{
            dumpRect(record.bounds),
            if (click) " click" else "",
            if (record.focusable) " focus" else "",
            if (key) " key" else "",
        });
    }
}

pub fn writeA11y(frame: *const records.Frame, out: *TextBuffer) void {
    for (frame.a11y[0..frame.a11y_count]) |*node| {
        testing.legacy_harness.writeA11yElement(out, node.depth, .{
            .role = node.role,
            .name = frame.text(node.name),
            .value = frame.text(node.value),
            .state = node.state,
            .bounds = dumpRect(node.bounds),
        });
    }
}

fn dumpRect(rect: records.Rect) testing.record_dump.Rect {
    return .{ .x = rect.x, .y = rect.y, .w = rect.width, .h = rect.height };
}

fn capture(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime App: type,
    trace: *const trace_mod.Trace,
    out: *TextBuffer,
) !void {
    const Driver = CoreDriver(App);
    const driver = try allocator.create(Driver);
    defer allocator.destroy(driver);
    try driver.initInPlace(allocator, io, trace);
    defer driver.deinit();
    trace_mod.run(driver, trace, out);
}

pub fn captureCounter(allocator: std.mem.Allocator, io: std.Io, out: *TextBuffer) !void {
    try capture(allocator, io, counter.App, &traces.counter, out);
}

pub fn captureTodo(allocator: std.mem.Allocator, io: std.Io, out: *TextBuffer) !void {
    try capture(allocator, io, todo.App, &traces.todo, out);
}
