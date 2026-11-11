//! The Metal backend: the `Renderer` contract (contract §9) over a
//! `CAMetalLayer`, drawing the packed frame.

pub const api = @import("api.zig");
pub const Renderer = @import("renderer.zig").Renderer;
pub const shaders = @import("shaders.zig");
