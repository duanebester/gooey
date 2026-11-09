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

// Re-export commonly used types and functions
pub const runCx = runner.runCx;
pub const CxConfig = runner.CxConfig;
pub const renderFrameCx = frame.renderFrameCx;
pub const handleInputCx = input.handleInputCx;
pub const renderCommand = render.renderCommand;
pub const renderFrameCxRuntime = frame.renderFrameCxRuntime;

// WindowContext for per-window state management
pub const WindowContext = window_context.WindowContext;

// Input utilities
pub const isControlKey = input.isControlKey;
pub const syncBoundVariablesCx = input.syncBoundVariablesCx;
pub const syncTextAreaBoundVariablesCx = input.syncTextAreaBoundVariablesCx;
