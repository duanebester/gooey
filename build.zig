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
    run_cmd.setEnvironmentVariable("MTL_HUD_ENABLED", "1");

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // =========================================================================
    // Simple Counter Example
    // =========================================================================

    const simple_exe = b.addExecutable(.{
        .name = "simple",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/simple.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(simple_exe);

    // Run simple example
    const run_simple_step = b.step("run-simple", "Run the simple counter example");
    const run_simple_cmd = b.addRunArtifact(simple_exe);
    run_simple_step.dependOn(&run_simple_cmd.step);
    run_simple_cmd.step.dependOn(b.getInstallStep());

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
    // Todo Example
    // =========================================================================

    const todo_exe = b.addExecutable(.{
        .name = "todo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/todo_app.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(todo_exe);

    // Run todo example
    const run_todo_step = b.step("run-todo", "Run the todo app example");
    const run_todo_cmd = b.addRunArtifact(todo_exe);
    run_todo_step.dependOn(&run_todo_cmd.step);
    run_todo_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Theme Example
    // =========================================================================

    const theme_exe = b.addExecutable(.{
        .name = "theme",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/theme.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(theme_exe);

    // Run theme example
    const run_theme_step = b.step("run-theme", "Run the theme example");
    const run_theme_cmd = b.addRunArtifact(theme_exe);
    run_theme_step.dependOn(&run_theme_cmd.step);
    run_theme_cmd.step.dependOn(b.getInstallStep());

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

    // =========================================================================
    // Login Form Example
    // =========================================================================

    const login_exe = b.addExecutable(.{
        .name = "login",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/login.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(login_exe);

    // Run login example
    const run_login_step = b.step("run-login", "Run the login form example");
    const run_login_cmd = b.addRunArtifact(login_exe);
    run_login_step.dependOn(&run_login_cmd.step);
    run_login_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Shader Demo Example
    // =========================================================================

    const shader_exe = b.addExecutable(.{
        .name = "shader_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/shader_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(shader_exe);

    // Run shader demo
    const run_shader_step = b.step("run-shader", "Run the custom shader demo");
    const run_shader_cmd = b.addRunArtifact(shader_exe);
    run_shader_step.dependOn(&run_shader_cmd.step);
    run_shader_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Focus Demo Example
    // =========================================================================

    const focus_exe = b.addExecutable(.{
        .name = "focus_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/focus_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(focus_exe);

    // Run focus demo
    const run_focus_step = b.step("run-focus", "Run the focus navigation demo");
    const run_focus_cmd = b.addRunArtifact(focus_exe);
    run_focus_step.dependOn(&run_focus_cmd.step);
    run_focus_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Actions Demo Example
    // =========================================================================

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
    // Context Demo Example
    // =========================================================================

    const context_exe = b.addExecutable(.{
        .name = "context_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/with_context.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(context_exe);

    // Run context demo
    const run_context_step = b.step("run-context", "Run the context/state demo");
    const run_context_cmd = b.addRunArtifact(context_exe);
    run_context_step.dependOn(&run_context_cmd.step);
    run_context_cmd.step.dependOn(b.getInstallStep());

    // =========================================================================
    // Entities Demo Example
    // =========================================================================

    const entities_exe = b.addExecutable(.{
        .name = "entities_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/entities.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = mod },
                .{ .name = "objc", .module = objc_dep.module("objc") },
            },
        }),
    });

    b.installArtifact(entities_exe);

    const run_entities_step = b.step("run-entities", "Run the entities demo");
    const run_entities_cmd = b.addRunArtifact(entities_exe);
    run_entities_step.dependOn(&run_entities_cmd.step);
    run_entities_cmd.step.dependOn(b.getInstallStep());

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
