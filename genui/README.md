# Gooey Gen UI

An optional, bounded generative-UI package for Gooey.

`gooey-genui` lets an application provide trusted component candidates, state,
and actions. An evaluator selects and arranges those candidates into a validated
tree, which the package renders with native Gooey components. Generated data
never supplies callbacks or executable code.

## Features

- Fixed-capacity composition, state, render traversal, and event queues.
- `Stack`, `Row`, `Card`, `Text`, `Button`, `Input`, and `Checkbox` components.
- Gooey themes, accessibility, retained control identity, and native controls.
- Model-neutral two-pass selection and layout interface.
- Direct TypeSafe Jev client with no Vercel AI Gateway dependency.
- Injectable transport and deterministic offline tests.

## Add the module

Gooey exports Gen UI as an optional sibling module, like `gooey-charts`:

```zig
const gooey_dependency = b.dependency("gooey", .{
    .target = target,
    .optimize = optimize,
});

const executable = b.addExecutable(.{
    .name = "my-app",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gooey", .module = gooey_dependency.module("gooey") },
            .{ .name = "gooey-genui", .module = gooey_dependency.module("gooey-genui") },
        },
    }),
});
```

Application code can then import both packages:

```zig
const gooey = @import("gooey");
const genui = @import("gooey-genui");
```

## Package layers

| Layer | Responsibility | Gooey dependency |
| --- | --- | --- |
| `core.zig` | Catalog, candidates, state, composition, and validation | No |
| `jev/` | Direct TypeSafe request codec, client, and evaluator | No |
| `renderer.zig` | Native Gooey rendering and bounded interaction events | Yes |

The application owns credentials, retries, request deadlines, worker
scheduling, and action dispatch. The Jev transport must run in a cancellable
`std.Io.Future`; the caller cancels that future when its request deadline
expires.

## Development

The parent Gooey build supplies the `gooey` import and platform linker setup:

```sh
zig build test-genui
zig build genui-demo
zig build run-genui-demo
```

See [`../docs/gen-ui.md`](../docs/gen-ui.md) for the architecture, invariants,
limits, and TypeSafe boundary.

## License

Same license as Gooey (see the repository root `LICENSE`).
