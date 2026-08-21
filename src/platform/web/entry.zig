//! Root module for freestanding browser builds.
//!
//! Examples are imported as child modules so their native `main` declaration
//! does not make Zig synthesize `std.start` for a freestanding executable.

const application = @import("application");

pub const std_options = application.std_options;

comptime {
    _ = application.wasm_app;
}
