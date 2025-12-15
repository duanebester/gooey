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

    b.installArtifact(exe);

    // Run step (default demo)
    const run_step = b.step("run", "Run the login form demo");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    // Enable Metal HUD for FPS/GPU stats
    //run_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");

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
