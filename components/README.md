# Gooey Components

Library controls (`components.Button`, `components.TextInput`, ...) and the
Lucide icon set (`components.Lucide`).

```zig
const gooey = @import("gooey");
const components = @import("gooey-components");

const Button = components.Button;

fn render(cx: *gooey.Cx) void {
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
