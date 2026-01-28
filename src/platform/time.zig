//! Platform-agnostic time utilities
//!
//! This module provides time functions that work across all platforms.
//! On native platforms, it delegates to `std.time`.
//! On WASM, it uses JavaScript's `Date.now()`.

const std = @import("std");
const builtin = @import("builtin");

pub const is_wasm = builtin.cpu.arch == .wasm32 or builtin.cpu.arch == .wasm64;

/// Returns the current timestamp in milliseconds since Unix epoch.
/// Works on both native platforms (via std.time) and WASM (via JS Date.now()).
pub fn milliTimestamp() i64 {
    if (is_wasm) {
        const web_imports = @import("web/imports.zig");
        return @intFromFloat(web_imports.getTimestampMillis());
    } else {
        return std.time.milliTimestamp();
    }
}

/// Returns the current timestamp in nanoseconds since Unix epoch.
/// On WASM, this converts from milliseconds (lower precision).
pub fn nanoTimestamp() i128 {
    if (is_wasm) {
        const millis = milliTimestamp();
        return @as(i128, millis) * std.time.ns_per_ms;
    } else {
        return std.time.nanoTimestamp();
    }
}

/// Returns a monotonic timestamp for measuring durations.
/// On native, uses std.time.Instant. On WASM, falls back to milliTimestamp.
pub const Instant = if (is_wasm) WasmInstant else std.time.Instant;

pub const WasmInstant = struct {
    timestamp_ms: i64,

    const Self = @This();

    pub fn now() Self {
        return .{ .timestamp_ms = milliTimestamp() };
    }

    pub fn since(self: Self, earlier: Self) u64 {
        const diff = self.timestamp_ms - earlier.timestamp_ms;
        if (diff < 0) return 0;
        return @intCast(diff * std.time.ns_per_ms);
    }
};
