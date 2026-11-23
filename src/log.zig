const std = @import("std");
const builtin = @import("builtin");

const is_freestanding = builtin.os.tag == .freestanding;

const MAX_LOG_MESSAGE_LEN = 4096;

pub fn scoped(comptime scope: @EnumLiteral()) type {
    if (is_freestanding) {
        return WasmLogger(scope);
    } else {
        return NativeLogger(scope);
    }
}

pub const default = scoped(.default);

fn NativeLogger(comptime scope: @EnumLiteral()) type {
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

fn WasmLogger(comptime scope: @EnumLiteral()) type {
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
