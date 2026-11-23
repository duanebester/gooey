test {
    _ = @import("platform/windows/clipboard.zig");
    _ = @import("platform/windows/core_host.zig");
    _ = @import("platform/windows/d3d11.zig");
    _ = @import("platform/windows/dx11_tests.zig");
    _ = @import("platform/windows/file_dialog.zig");
    _ = @import("platform/windows/shell.zig");
    _ = @import("platform/windows/ime.zig");
    _ = @import("platform/windows/input.zig");
    _ = @import("platform/windows/uia.zig");
    _ = @import("platform/windows/win32.zig");
    _ = @import("accessibility/windows_snapshot.zig");
    _ = @import("accessibility/windows_provider.zig");
    _ = @import("accessibility/windows_bridge.zig");
    _ = @import("text/backends/directwrite/mod.zig");
    _ = @import("image/backends/wic/tests.zig");
    _ = @import("svg/atlas.zig");
}
