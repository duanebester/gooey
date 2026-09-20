# Gooey Components

High-level controls built on Gooey's public declarative UI API.

```zig
const gooey = @import("gooey");
const components = @import("gooey-components");

fn render(cx: *gooey.Cx) void {
    cx.render(components.Button{
        .label = "Save",
        .on_click_handler = cx.update(State.save),
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
