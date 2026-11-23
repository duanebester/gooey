pub const platform = @import("platform.zig");
pub const window = @import("window.zig");
pub const window_delegate = @import("window_delegate.zig");

pub const metal = @import("metal/metal.zig");

pub const clipboard = @import("clipboard.zig");
pub const file_dialog = @import("file_dialog.zig");

pub const appkit = @import("appkit.zig");

pub const input_view = @import("input_view.zig");

const interface = @import("../interface.zig");

pub const Platform = platform.MacPlatform;
pub const PlatformWindow = window.Window;

pub const MacPlatform = platform.MacPlatform;
pub const Window = window.Window;
pub const Renderer = metal.Renderer;

pub const WindowOptions = interface.WindowOptions;
pub const CursorShape = interface.CursorShape;
pub const PathPromptOptions = interface.PathPromptOptions;
pub const PathPromptResult = interface.PathPromptResult;
pub const SavePromptOptions = interface.SavePromptOptions;
