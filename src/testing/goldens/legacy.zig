//! Trace driver for the 0.3.1 runtime (`gooey.testing.LegacyHarness`).
//!
//! Each recorded frame is handed to a `NullRenderer` exactly as a platform
//! window hands it to Metal or Vulkan, and the renderer's dump becomes the
//! paint section of the golden.

const std = @import("std");
const gooey = @import("gooey");
const counter = @import("counter_example");
const todo = @import("todo_example");
const trace_mod = @import("trace.zig");
const traces = @import("traces.zig");

const assert = std.debug.assert;

const testing = gooey.testing;
const TextBuffer = testing.record_dump.TextBuffer;
const NullRenderer = testing.NullRenderer;
const core_backend = gooey.core.backend;

/// The 0.3.1 runner's default window background, which is the clear colour
/// every example without `background_color` presents with.
const clear_color = gooey.Color.rgba(0.95, 0.95, 0.95, 1.0);

pub const LegacyDriver = struct {
    harness: testing.LegacyHarness,
    renderer: NullRenderer,

    const Self = @This();

    pub fn deliver(self: *Self, event: gooey.input.InputEvent) void {
        self.harness.input(event);
    }

    pub fn frame(self: *Self) void {
        self.harness.frame() catch |err| std.debug.panic("legacy frame failed: {s}", .{
            @errorName(err),
        });
        const size = self.harness.viewportSize();
        self.renderer.draw(self.harness.packedFrame(), .{
            .size_px = .{
                .width = @intFromFloat(size.width * size.scale),
                .height = @intFromFloat(size.height * size.scale),
            },
            .scale_factor = size.scale,
        }, clear_color);
        assert(self.renderer.draw_count == self.harness.frame_count);
    }

    pub fn writeRecord(self: *const Self, out: *TextBuffer) void {
        assert(self.renderer.draw_count > 0);
        out.print("{s}", .{self.renderer.frameDump()});
        out.print("hits\n", .{});
        self.harness.writeHits(out);
        out.print("a11y\n", .{});
        self.harness.writeA11y(out);
    }
};

/// Run `trace` against the legacy runtime with `State` and `render`.
fn capture(
    allocator: std.mem.Allocator,
    io: std.Io,
    comptime State: type,
    comptime render: fn (*gooey.Cx) void,
    limits: gooey.ResourceLimits,
    font_limits: gooey.core.limits.FontLimits,
    trace: *const trace_mod.Trace,
    out: *TextBuffer,
) !void {
    var state: State = .{};
    const driver = try allocator.create(LegacyDriver);
    defer allocator.destroy(driver);

    const options = testing.legacy_harness.Options{
        .width = trace.width,
        .height = trace.height,
        .scale_factor = trace.scale_factor,
        .limits = limits,
        .font_limits = font_limits,
    };
    try driver.harness.initInPlace(allocator, io, State, &state, render, &options);
    defer driver.harness.deinit();

    const render_limits = core_backend.RenderLimits.fromResourceLimits(&limits);
    const surface = core_backend.Surface{
        .native = null,
        .size_px = .{
            .width = @intFromFloat(trace.width * trace.scale_factor),
            .height = @intFromFloat(trace.height * trace.scale_factor),
        },
        .scale_factor = trace.scale_factor,
    };
    try driver.renderer.initInPlace(&surface, &render_limits);
    defer driver.renderer.deinit();
    driver.renderer.observeGlyphAtlas(driver.harness.glyphAtlas());

    trace_mod.run(driver, trace, out);
}

pub fn captureCounter(allocator: std.mem.Allocator, io: std.Io, out: *TextBuffer) !void {
    try capture(
        allocator,
        io,
        counter.AppState,
        counter.render,
        .nano,
        .nano,
        &traces.counter,
        out,
    );
}

pub fn captureTodo(allocator: std.mem.Allocator, io: std.Io, out: *TextBuffer) !void {
    try capture(allocator, io, todo.AppState, todo.render, .small, .small, &traces.todo, out);
}
