const application = @import("application");
const gooey = @import("gooey");

pub const std_options = if (@hasDecl(application, "std_options"))
    application.std_options
else
    gooey.std_options;

comptime {
    _ = application.App;
}
