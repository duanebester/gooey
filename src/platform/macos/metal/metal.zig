//! Metal rendering module for gooey
//!
//! This module provides a clean, modular Metal API wrapper inspired by Ghostty.

// Core Metal API types
pub const api = @import("api.zig");

// Shader sources
pub const quad = @import("quad.zig");
pub const shadow = @import("shadow.zig");

// Main renderer
pub const Renderer = @import("renderer.zig").Renderer;
pub const Vertex = @import("renderer.zig").Vertex;
pub const ScissorRect = @import("renderer.zig").ScissorRect;

// Submodules (for advanced usage)
pub const pipelines = @import("pipelines.zig");
pub const render_pass = @import("render_pass.zig");
pub const scene_renderer = @import("scene_renderer.zig");
pub const post_process = @import("post_process.zig");
pub const scissor = @import("scissor.zig");
pub const text = @import("text.zig");
pub const custom_shader = @import("custom_shader.zig");
