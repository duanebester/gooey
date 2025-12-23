const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Only load zig-objc dependency and setup native module on macOS
    const is_native_macos = target.result.os.tag == .macos;

    if (is_native_macos) {
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
                .root_source_file = b.path("src/examples/showcase.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gooey", .module = mod },
                    .{ .name = "objc", .module = objc_dep.module("objc") },
                },
            }),
        });

        // Run step (default demo)
        const run_step = b.step("run", "Run the showcase demo");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        // Enable Metal HUD for FPS/GPU stats
        // run_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        // =========================================================================
        // Native Mac Examples
        // =========================================================================

        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "pomodoro", "src/examples/pomodoro.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "animation", "src/examples/animation.zig", true);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "spaceship", "src/examples/spaceship.zig", true);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "glass", "src/examples/glass.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "counter", "src/examples/counter.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "layout", "src/examples/layout.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "dynamic-counters", "src/examples/dynamic_counters.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "actions", "src/examples/actions.zig", false);

        // =====================================================================
        // Tests
        // =====================================================================

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

        // =====================================================================
        // Hot Reload Watcher
        // =====================================================================

        const watcher_exe = b.addExecutable(.{
            .name = "gooey-hot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/hot/watcher.zig"),
                .target = target,
                .optimize = .Debug,
            }),
        });

        b.installArtifact(watcher_exe);

        const hot_step = b.step("hot", "Run with hot reload (watches src/ for changes)");

        const watcher_cmd = b.addRunArtifact(watcher_exe);
        watcher_cmd.addArg("src");

        if (b.args) |args| {
            watcher_cmd.addArg("zig");
            watcher_cmd.addArg("build");
            for (args) |arg| {
                watcher_cmd.addArg(arg);
            }
        } else {
            watcher_cmd.addArg("zig");
            watcher_cmd.addArg("build");
            watcher_cmd.addArg("run");
        }

        hot_step.dependOn(&watcher_cmd.step);
    }

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
    gooey_wasm_module.addAnonymousImport("svg_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/svg.wgsl"),
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
    addWasmExample(b, gooey_wasm_module, wasm_target, "spaceship", "src/examples/spaceship.zig", "web/spaceship");
}

/// Helper to add a native macOS example with minimal boilerplate.
fn addNativeExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    objc_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
    metal_hud: bool,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
                .{ .name = "objc", .module = objc_module },
            },
        }),
    });

    b.installArtifact(exe);

    const step_name = b.fmt("run-{s}", .{name});
    const step_desc = b.fmt("Run the {s} example", .{name});
    const step = b.step(step_name, step_desc);

    const run_cmd = b.addRunArtifact(exe);
    if (metal_hud) {
        run_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");
    }
    step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
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
