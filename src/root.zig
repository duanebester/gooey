//! guiz - A minimal GPU-accelerated UI framework for Zig
//! Inspired by GPUI, targeting macOS with Metal rendering.

const std = @import("std");

// Re-export core types
pub const geometry = @import("core/geometry.zig");
pub const Size = geometry.Size;
pub const Point = geometry.Point;
pub const Rect = geometry.Rect;
pub const Color = geometry.Color;

// Scene and primitives
pub const scene = @import("core/scene.zig");
pub const Scene = scene.Scene;
pub const Quad = scene.Quad;
pub const Shadow = scene.Shadow;
pub const Hsla = scene.Hsla;

// Re-export platform types
pub const platform = @import("platform/mac/platform.zig");
pub const MacPlatform = platform.MacPlatform;
pub const Window = @import("platform/mac/window.zig").Window;
pub const DisplayLink = @import("platform/mac/display_link.zig").DisplayLink;

// App context
pub const App = @import("core/app.zig").App;

test {
    std.testing.refAllDecls(@This());
}
