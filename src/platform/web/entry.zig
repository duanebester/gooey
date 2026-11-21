// Imported as a child module so its native `main` does not make Zig
// synthesize `std.start` for a freestanding executable; its `App` type
// generates the exports.

const application = @import("application");
const gooey = @import("gooey");

pub const std_options = if (@hasDecl(application, "std_options"))
    application.std_options
else
    gooey.std_options;

comptime {
    _ = application.App;
}
