//! Metal rendering module for guiz
//!
//! This module provides a clean, modular Metal API wrapper inspired by Ghostty.

pub const api = @import("api.zig");
pub const shaders = @import("shaders.zig");
pub const Renderer = @import("renderer.zig").Renderer;
pub const Vertex = @import("renderer.zig").Vertex;
