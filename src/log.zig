//! Platform-aware logger for Gooey applications.
//!
//! Provides a `std.log.scoped()`-compatible API that works on all platforms
//! without requiring `pub const std_options` in the user's root file.
//!
//! On native targets, delegates to `std.log.scoped()`.
//! On WASM/freestanding, writes directly to the browser console.
//!
//! Usage:
//! ```
//! const log = gooey.log.scoped(.myapp);
//! log.info("connected to {s}", .{host});
//! log.err("request failed: {}", .{code});
//! ```

const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

const MAX_LOG_MESSAGE_LEN = 4096;

/// Returns a scoped logger for the given tag.
///
/// On native: delegates to `std.log.scoped(scope)`.
/// On WASM:   formats and writes directly to `console.log` / `console.error`.
pub fn scoped(comptime scope: @Type(.enum_literal)) type {
    if (is_freestanding) {
        return WasmLogger(scope);
    } else {
        return NativeLogger(scope);
    }
}

/// Default (unscoped) logger — equivalent to `scoped(.default)`.
pub const default = scoped(.default);

// =============================================================================
// Native logger — thin wrapper around std.log.scoped
// =============================================================================

fn NativeLogger(comptime scope: @Type(.enum_literal)) type {
    const std_scoped = std.log.scoped(scope);

    return struct {
        pub fn err(comptime format: []const u8, args: anytype) void {
            std_scoped.err(format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            std_scoped.warn(format, args);
        }

        pub fn info(comptime format: []const u8, args: anytype) void {
            std_scoped.info(format, args);
        }

        pub fn debug(comptime format: []const u8, args: anytype) void {
            std_scoped.debug(format, args);
        }
    };
}

// =============================================================================
// WASM logger — writes directly to browser console, no std_options needed
// =============================================================================

fn WasmLogger(comptime scope: @Type(.enum_literal)) type {
    return struct {
        const scope_prefix = if (scope == .default)
            ""
        else
            "(" ++ @tagName(scope) ++ ") ";

        pub fn err(comptime format: []const u8, args: anytype) void {
            doLog(.err, format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            doLog(.warn, format, args);
        }

        pub fn info(comptime format: []const u8, args: anytype) void {
            doLog(.info, format, args);
        }

        pub fn debug(comptime format: []const u8, args: anytype) void {
            doLog(.debug, format, args);
        }

        fn doLog(
            comptime level: std.log.Level,
            comptime format: []const u8,
            args: anytype,
        ) void {
            const level_prefix = comptime levelString(level);
            const full_prefix = level_prefix ++ scope_prefix;

            var buf: [MAX_LOG_MESSAGE_LEN]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, full_prefix ++ format, args) catch blk: {
                // Message too long — emit what we can with a truncation marker.
                const marker = "...[truncated]";
                std.debug.assert(buf.len > marker.len);
                @memcpy(buf[buf.len - marker.len ..], marker);
                break :blk &buf;
            };

            const web = @import("platform/web/imports.zig");
            std.debug.assert(msg.len > 0);
            std.debug.assert(msg.len <= MAX_LOG_MESSAGE_LEN);

            if (level == .err) {
                web.consoleError(msg.ptr, @intCast(msg.len));
            } else {
                web.consoleLog(msg.ptr, @intCast(msg.len));
            }
        }

        fn levelString(comptime level: std.log.Level) []const u8 {
            return switch (level) {
                .err => "[error] ",
                .warn => "[warn] ",
                .info => "[info] ",
                .debug => "[debug] ",
            };
        }
    };
}
