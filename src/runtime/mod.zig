//! Runtime Module
//!
//! Platform initialization, event loop, frame rendering, and input handling.
//! This module orchestrates the lifecycle of a gooey application.

pub const runner = @import("runner.zig");
pub const frame = @import("frame.zig");
pub const input = @import("input.zig");
pub const render = @import("render.zig");
pub const watcher = @import("watcher.zig");
pub const window_context = @import("window_context.zig");
pub const window_handle = @import("window_handle.zig");
pub const multi_window_app = @import("multi_window_app.zig");

// Re-export commonly used types and functions
pub const runCx = runner.runCx;
pub const CxConfig = runner.CxConfig;
pub const renderFrameCx = frame.renderFrameCx;
pub const handleInputCx = input.handleInputCx;
pub const renderCommand = render.renderCommand;
pub const renderFrameCxRuntime = frame.renderFrameCxRuntime;

// WindowContext for per-window state management
pub const WindowContext = window_context.WindowContext;

// WindowHandle for type-safe cross-window communication
pub const WindowHandle = window_handle.WindowHandle;

// Multi-window App for managing multiple windows with shared resources
pub const MultiWindowApp = multi_window_app.App;
pub const AppWindowOptions = multi_window_app.AppWindowOptions;
pub const MAX_WINDOWS = multi_window_app.MAX_WINDOWS;

// Input utilities
pub const isControlKey = input.isControlKey;
pub const syncBoundVariablesCx = input.syncBoundVariablesCx;
pub const syncTextAreaBoundVariablesCx = input.syncTextAreaBoundVariablesCx;
