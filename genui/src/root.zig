//! Bounded catalog-constrained composition for Gooey.

pub const core = @import("core.zig");
pub const jev = struct {
    pub const codec = @import("jev/codec.zig");
    pub const client = @import("jev/client.zig");
    pub const evaluator = @import("jev/evaluator.zig");
};
pub const Renderer = @import("renderer.zig").Renderer;
pub const Artifact = @import("renderer.zig").Artifact;
pub const ActionEvent = @import("renderer.zig").ActionEvent;
pub const ValueEvent = @import("renderer.zig").ValueEvent;

pub const Catalog = core.Catalog;
pub const Candidate = core.Candidate;
pub const CandidateSet = core.CandidateSet;
pub const RuntimeState = core.RuntimeState;
pub const StateInput = core.StateInput;
pub const StateValue = core.StateValue;
pub const Spec = core.Spec;
pub const Evaluator = core.Evaluator;
pub const compose = core.compose;
pub const validateSpec = core.validateSpec;

test {
    _ = core;
    _ = jev.codec;
    _ = jev.client;
    _ = jev.evaluator;
    _ = @import("renderer.zig");
}
