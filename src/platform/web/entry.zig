//! Root module for freestanding browser builds.
//!
//! Examples are imported as child modules so their native `main` declaration
//! does not make Zig synthesize `std.start` for a freestanding executable.
//! Each example names its `gooey.App` as `App`, whose type generates the
//! exports.

const application = @import("application");
const gooey = @import("gooey");

pub const std_options = if (@hasDecl(application, "std_options"))
    application.std_options
else
    gooey.std_options;

comptime {
    _ = application.App;
}
