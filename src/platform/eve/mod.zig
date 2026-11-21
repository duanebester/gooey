pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const chip = @import("chip.zig");
pub const display_list = @import("display_list.zig");
pub const cells = @import("cells.zig");
pub const renderer = @import("renderer.zig");
pub const images = @import("images.zig");
pub const limits = @import("limits.zig");

// The names `platform/mod.zig` aliases as `Platform` and `PlatformWindow`.
pub const Platform = platform.EvePlatform;
pub const PlatformWindow = window.Window;

test {
    _ = chip;
    _ = display_list;
    _ = cells;
    _ = renderer;
    _ = images;
    _ = limits;
}
