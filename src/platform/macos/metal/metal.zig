//! The Metal backend: a `Renderer` over a `CAMetalLayer`, drawing the packed
//! frame.

pub const api = @import("api.zig");
pub const Renderer = @import("renderer.zig").Renderer;
pub const shaders = @import("shaders.zig");
