//! Root module for freestanding browser builds.
//!
//! Examples are imported as child modules so their native `main` declaration
//! does not make Zig synthesize `std.start` for a freestanding executable.
//! A 0.3.1 example names its `WebApp` as `wasm_app`; a 0.4.0 core example
//! names its `gooey.App` as `App`, whose type generates the exports.

const application = @import("application");
const gooey = @import("gooey");

pub const std_options = if (@hasDecl(application, "std_options"))
    application.std_options
else
    gooey.std_options;

comptime {
    if (@hasDecl(application, "wasm_app")) {
        _ = application.wasm_app;
    } else {
        _ = application.App;
    }
}
