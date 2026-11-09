# Gooey Components

Controls on the Gooey core (`components.core`) and the Lucide icon set
(`components.Lucide`).

```zig
const gooey = @import("gooey");
const components = @import("gooey-components");

const Button = components.core.Button;

fn render(cx: *gooey.core.Cx) void {
    cx.render(Button{
        .label = "Save",
        .on_click = cx.on(State.save, .{}),
    });
}
```

Add both modules from the same Gooey dependency so component and application
types share one Gooey module instance:

```zig
.imports = &.{
    .{ .name = "gooey", .module = gooey_dependency.module("gooey") },
    .{
        .name = "gooey-components",
        .module = gooey_dependency.module("gooey-components"),
    },
},
```
