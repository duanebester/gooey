//! Browser-backed `std.Io` clock support.
//!
//! Browser applications use explicit JavaScript callbacks for asynchronous
//! services, so unsupported operations retain `std.Io.failing` semantics.
//! Clocks are the exception: animation and interaction timing require a
//! monotonically advancing source even though no general-purpose WASM I/O
//! backend exists.

const std = @import("std");
const imports = @import("imports.zig");

const nanoseconds_per_millisecond: f64 = @floatFromInt(std.time.ns_per_ms);

pub const browser: std.Io = .{
    .userdata = null,
    .vtable = &browser_vtable,
};

const browser_vtable: std.Io.VTable = blk: {
    var vtable = std.Io.failing.vtable.*;
    vtable.now = now;
    vtable.clockResolution = clockResolution;
    break :blk vtable;
};

comptime {
    std.debug.assert(browser_vtable.now != std.Io.failing.vtable.now);
    std.debug.assert(browser_vtable.clockResolution != std.Io.failing.vtable.clockResolution);
}

fn now(userdata: ?*anyopaque, clock: std.Io.Clock) std.Io.Timestamp {
    std.debug.assert(userdata == null);

    const milliseconds = switch (clock) {
        .real => imports.getTimestampMillis(),
        .awake, .boot => imports.getFrameTime(),
        .cpu_process, .cpu_thread => return .zero,
    };
    std.debug.assert(std.math.isFinite(milliseconds));
    std.debug.assert(milliseconds >= 0);

    const nanoseconds: i96 = @intFromFloat(milliseconds * nanoseconds_per_millisecond);
    return std.Io.Timestamp.fromNanoseconds(nanoseconds);
}

fn clockResolution(
    userdata: ?*anyopaque,
    clock: std.Io.Clock,
) std.Io.Clock.ResolutionError!std.Io.Duration {
    std.debug.assert(userdata == null);
    std.debug.assert(std.time.ns_per_ms > 0);

    return switch (clock) {
        .real, .awake, .boot => .{ .nanoseconds = std.time.ns_per_ms },
        .cpu_process, .cpu_thread => error.ClockUnavailable,
    };
}
