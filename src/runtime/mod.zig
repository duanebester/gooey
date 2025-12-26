//! Runtime Module
//!
//! Platform initialization, event loop, frame rendering, and input handling.
//! This module orchestrates the lifecycle of a gooey application.

pub const runner = @import("runner.zig");
pub const frame = @import("frame.zig");
pub const input = @import("input.zig");
pub const render = @import("render.zig");

// Re-export commonly used types and functions
pub const runCx = runner.runCx;
pub const CxConfig = runner.CxConfig;
pub const renderFrameCx = frame.renderFrameCx;
pub const renderFrameWithContext = frame.renderFrameWithContext;
pub const handleInputCx = input.handleInputCx;
pub const handleInputWithContext = input.handleInputWithContext;
pub const renderCommand = render.renderCommand;

// Input utilities
pub const isControlKey = input.isControlKey;
pub const syncBoundVariablesCx = input.syncBoundVariablesCx;
pub const syncTextAreaBoundVariablesCx = input.syncTextAreaBoundVariablesCx;
pub const syncBoundVariablesWithContext = input.syncBoundVariablesWithContext;
pub const syncTextAreaBoundVariablesWithContext = input.syncTextAreaBoundVariablesWithContext;
