const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get the zig-objc dependency
    const objc_dep = b.dependency("zig_objc", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the gooey module
    const mod = b.addModule("gooey", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("objc", objc_dep.module("objc"));

    // Link macOS frameworks to the module (needed for tests too)
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("CoreVideo", .{});
    mod.linkFramework("CoreText", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.link_libc = true;

    // =========================================================================
    // Main Demo (Showcase)
    // =========================================================================

    const exe = b.addExecutable(.{
        .name = "gooey",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/showcase.zig"), // Changed!
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    // Run step (default demo)
    const run_step = b.step("run", "Run the login form demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // Enable Metal HUD for FPS/GPU stats
    run_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // =========================================================================
    // Pomodoro Example
    // =========================================================================

    const pomodoro_exe = b.addExecutable(.{
        .name = "pomodoro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/pomodoro.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(pomodoro_exe);

    // Run pomodoro example
    const run_pomodoro_step = b.step("run-pomodoro", "Run the pomodoro example");
    const run_pomodoro_cmd = b.addRunArtifact(pomodoro_exe);
    run_pomodoro_step.dependOn(&run_pomodoro_cmd.step);
    run_pomodoro_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Animation Example
    // =========================================================================

    const animation_exe = b.addExecutable(.{
        .name = "animation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/animation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(animation_exe);

    // Run animation example
    const run_animation_step = b.step("run-animation", "Run the animation example");
    const run_animation_cmd = b.addRunArtifact(animation_exe);
    run_animation_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");
    run_animation_step.dependOn(&run_animation_cmd.step);
    run_animation_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Spaceship Example
    // =========================================================================

    const spaceship_exe = b.addExecutable(.{
        .name = "spaceship",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/spaceship.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(spaceship_exe);

    // Run spaceship example
    const run_spaceship_step = b.step("run-spaceship", "Run the spaceship example");
    const run_spaceship_cmd = b.addRunArtifact(spaceship_exe);
    run_spaceship_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");
    run_spaceship_step.dependOn(&run_spaceship_cmd.step);
    run_spaceship_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Liquid Glass Example
    // =========================================================================

    const glass_exe = b.addExecutable(.{
        .name = "glass",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/glass.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(glass_exe);

    // Run glass example
    const run_glass_step = b.step("run-glass", "Run the glass example");
    const run_glass_cmd = b.addRunArtifact(glass_exe);
    run_glass_step.dependOn(&run_glass_cmd.step);
    run_glass_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Counter Example
    // =========================================================================

    const counter_exe = b.addExecutable(.{
        .name = "counter",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/counter.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(counter_exe);

    // Run counter example
    const run_counter_step = b.step("run-counter", "Run the counter example");
    const run_counter_cmd = b.addRunArtifact(counter_exe);
    run_counter_step.dependOn(&run_counter_cmd.step);
    run_counter_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Layout Example
    // =========================================================================

    const layout_exe = b.addExecutable(.{
        .name = "layout",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/layout.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(layout_exe);

    // Run layout example
    const run_layout_step = b.step("run-layout", "Run the layout example");
    const run_layout_cmd = b.addRunArtifact(layout_exe);
    run_layout_step.dependOn(&run_layout_cmd.step);
    run_layout_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Dynamic Counters Example
    // =========================================================================

    const dynamic_counters_exe = b.addExecutable(.{
        .name = "dynamic_counters",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/dynamic_counters.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(dynamic_counters_exe);

    // Run dynamic_counters example
    const run_dynamic_counters_step = b.step("run-dynamic-counters", "Run the dynamic_counters example");
    const run_dynamic_counters_cmd = b.addRunArtifact(dynamic_counters_exe);
    run_dynamic_counters_step.dependOn(&run_dynamic_counters_cmd.step);
    run_dynamic_counters_cmd.step.dependOn(b.getInstallStep());

    const actions_exe = b.addExecutable(.{
        .name = "actions_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/actions.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(actions_exe);

    // Run focus demo
    const run_actions_step = b.step("run-actions", "Run the actions demo");
    const run_actions_cmd = b.addRunArtifact(actions_exe);
    run_actions_step.dependOn(&run_actions_cmd.step);
    run_actions_cmd.step.dependOn(b.getInstallStep());

    // =============================================================================
    // WebAssembly Builds
    // =============================================================================

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });

    // Create gooey module for WASM (shared by all examples)
    const gooey_wasm_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });

    // Add shader embeds (needed by renderer.zig)
    gooey_wasm_module.addAnonymousImport("unified_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/unified.wgsl"),
    });
    gooey_wasm_module.addAnonymousImport("text_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/text.wgsl"),
    });

    // -------------------------------------------------------------------------
    // WASM Examples
    // -------------------------------------------------------------------------

    // Main demo: "zig build wasm" builds showcase (matches "zig build run")
    {
        const wasm_exe = b.addExecutable(.{
            .name = "app",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/examples/showcase.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
                .imports = &.{
                    .{ .name = "gooey", .module = gooey_wasm_module },
                },
            }),
        });
        wasm_exe.entry = .disabled;
        wasm_exe.rdynamic = true;

        const wasm_step = b.step("wasm", "Build showcase for web (main demo)");
        wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        }).step);
        wasm_step.dependOn(&b.addInstallFile(b.path("web/index.html"), "web/index.html").step);
    }

    // Individual examples
    addWasmExample(b, gooey_wasm_module, wasm_target, "counter", "src/examples/counter.zig", "web/counter");
    addWasmExample(b, gooey_wasm_module, wasm_target, "dynamic-counters", "src/examples/dynamic_counters.zig", "web/dynamic");
    addWasmExample(b, gooey_wasm_module, wasm_target, "pomodoro", "src/examples/pomodoro.zig", "web/pomodoro");

    // =========================================================================
    // Hot Reload Watcher
    // =========================================================================

    const watcher_exe = b.addExecutable(.{
        .name = "gooey-hot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hot/watcher.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });

    b.installArtifact(watcher_exe);

    // Default target to run (can be overridden with -- args)
    const hot_step = b.step("hot", "Run with hot reload (watches src/ for changes)");

    const watcher_cmd = b.addRunArtifact(watcher_exe);
    watcher_cmd.addArg("src"); // Watch directory

    // Check if user provided custom args like "run-counter"
    if (b.args) |args| {
        // User provided args: zig build hot -- run-counter
        watcher_cmd.addArg("zig");
        watcher_cmd.addArg("build");
        for (args) |arg| {
            watcher_cmd.addArg(arg);
        }
    } else {
        // Default: zig build run
        watcher_cmd.addArg("zig");
        watcher_cmd.addArg("build");
        watcher_cmd.addArg("run");
    }

    hot_step.dependOn(&watcher_cmd.step);

    // =========================================================================
    // Tests
    // =========================================================================

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}

/// Helper to add a WASM example with minimal boilerplate.
/// All examples output as "app.wasm" so index.html works universally.
fn addWasmExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    wasm_target: std.Build.ResolvedTarget,
    name: []const u8,
    source: []const u8,
    output_dir: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
            },
        }),
    });

    exe.entry = .disabled;
    exe.rdynamic = true;

    const step_name = b.fmt("wasm-{s}", .{name});
    const step_desc = b.fmt("Build {s} example for web", .{name});
    const step = b.step(step_name, step_desc);

    step.dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .{ .custom = output_dir } },
    }).step);

    step.dependOn(&b.addInstallFile(
        b.path("web/index.html"),
        b.fmt("{s}/index.html", .{output_dir}),
    ).step);
}
