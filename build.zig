const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Platform detection
    const is_native_macos = target.result.os.tag == .macos;
    const is_native_linux = target.result.os.tag == .linux;

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
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "select", "src/examples/select.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "dynamic-counters", "src/examples/dynamic_counters.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "actions", "src/examples/actions.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "text-debug", "src/examples/text_debug_example.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "images", "src/examples/images.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "tooltip", "src/examples/tooltip.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "modal", "src/examples/modal.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "file-dialog", "src/examples/file_dialog.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "uniform-list", "src/examples/uniform_list_example.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "virtual-list", "src/examples/virtual_list_example.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "data-table", "src/examples/data_table_example.zig", false);

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
                .root_source_file = b.path("src/runtime/watcher.zig"),
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
    // Linux Native Builds (Vulkan + Wayland)
    // =============================================================================

    if (is_native_linux) {
        // =========================================================================
        // Shader Compilation (GLSL -> SPIR-V)
        // =========================================================================
        // Compiles shaders to source tree so @embedFile can find them.
        // Pre-committed .spv files mean this only needs to run when shaders change.

        const compile_shaders_step = b.step("compile-shaders", "Compile GLSL shaders to SPIR-V (requires glslc)");

        const shader_dir = "src/platform/linux/shaders";
        const shaders = [_]struct { source: []const u8, output: []const u8, stage: []const u8 }{
            .{ .source = "unified.vert", .output = "unified.vert.spv", .stage = "vertex" },
            .{ .source = "unified.frag", .output = "unified.frag.spv", .stage = "fragment" },
            .{ .source = "text.vert", .output = "text.vert.spv", .stage = "vertex" },
            .{ .source = "text.frag", .output = "text.frag.spv", .stage = "fragment" },
            .{ .source = "svg.vert", .output = "svg.vert.spv", .stage = "vertex" },
            .{ .source = "svg.frag", .output = "svg.frag.spv", .stage = "fragment" },
            .{ .source = "image.vert", .output = "image.vert.spv", .stage = "vertex" },
            .{ .source = "image.frag", .output = "image.frag.spv", .stage = "fragment" },
        };

        inline for (shaders) |shader| {
            const compile_cmd = b.addSystemCommand(&.{
                "glslc",
                "-fshader-stage=" ++ shader.stage,
                "-O", // Optimize for release
                "-o",
                shader_dir ++ "/" ++ shader.output,
                shader_dir ++ "/" ++ shader.source,
            });
            compile_shaders_step.dependOn(&compile_cmd.step);
        }

        // Create the gooey module for Linux
        const mod = b.addModule("gooey", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });

        // Link Vulkan
        mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include" });
        mod.linkSystemLibrary("vulkan", .{});

        // Link text rendering libraries (FreeType, HarfBuzz, Fontconfig)
        mod.linkSystemLibrary("freetype", .{});
        mod.linkSystemLibrary("harfbuzz", .{});
        mod.linkSystemLibrary("fontconfig", .{});
        // Link image loading library (libpng)
        mod.linkSystemLibrary("png", .{});
        // Link D-Bus for XDG portal file dialogs
        mod.linkSystemLibrary("dbus-1", .{});
        mod.link_libc = true;

        // =========================================================================
        // Linux Showcase (Main Demo)
        // =========================================================================

        const exe = b.addExecutable(.{
            .name = "gooey",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/examples/showcase.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gooey", .module = mod },
                },
            }),
        });

        // Link system libraries (Vulkan + Wayland + text rendering)
        exe.linkSystemLibrary("vulkan");
        exe.linkSystemLibrary("wayland-client");
        exe.linkSystemLibrary("freetype");
        exe.linkSystemLibrary("harfbuzz");
        exe.linkSystemLibrary("fontconfig");
        exe.linkSystemLibrary("png");
        exe.linkSystemLibrary("dbus-1");
        exe.linkLibC();

        b.installArtifact(exe);

        // Run step
        const run_step = b.step("run", "Run the showcase demo");
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.setCwd(b.path(".")); // Run from project root so assets/ can be found
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        // =========================================================================
        // Linux Basic Demo (Simple Wayland + Vulkan test)
        // =========================================================================

        const basic_exe = b.addExecutable(.{
            .name = "gooey-basic",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/examples/linux_demo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gooey", .module = mod },
                },
            }),
        });

        basic_exe.linkSystemLibrary("vulkan");
        basic_exe.linkSystemLibrary("wayland-client");
        basic_exe.linkSystemLibrary("freetype");
        basic_exe.linkSystemLibrary("harfbuzz");
        basic_exe.linkSystemLibrary("fontconfig");
        basic_exe.linkSystemLibrary("png");
        basic_exe.linkSystemLibrary("dbus-1");
        basic_exe.linkLibC();

        b.installArtifact(basic_exe);

        const run_basic_step = b.step("run-basic", "Run the basic Linux demo (simple Wayland + Vulkan test)");
        const run_basic_cmd = b.addRunArtifact(basic_exe);
        run_basic_cmd.setCwd(b.path(".")); // Run from project root so assets/ can be found
        run_basic_step.dependOn(&run_basic_cmd.step);
        run_basic_cmd.step.dependOn(b.getInstallStep());

        // =========================================================================
        // Linux Text Demo (uses full UI framework with text rendering)
        // =========================================================================

        const text_exe = b.addExecutable(.{
            .name = "gooey-text",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/examples/linux_text_demo.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gooey", .module = mod },
                },
            }),
        });

        text_exe.linkSystemLibrary("vulkan");
        text_exe.linkSystemLibrary("wayland-client");
        text_exe.linkSystemLibrary("freetype");
        text_exe.linkSystemLibrary("harfbuzz");
        text_exe.linkSystemLibrary("fontconfig");
        text_exe.linkSystemLibrary("png");
        text_exe.linkSystemLibrary("dbus-1");
        text_exe.linkLibC();

        b.installArtifact(text_exe);

        const run_text_step = b.step("run-text", "Run the Linux text demo");
        const run_text_cmd = b.addRunArtifact(text_exe);
        run_text_cmd.setCwd(b.path(".")); // Run from project root so assets/ can be found
        run_text_step.dependOn(&run_text_cmd.step);
        run_text_cmd.step.dependOn(b.getInstallStep());

        // =========================================================================
        // Linux File Dialog Demo
        // =========================================================================

        const file_dialog_exe = b.addExecutable(.{
            .name = "gooey-file-dialog",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/examples/linux_file_dialog.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "gooey", .module = mod },
                },
            }),
        });

        file_dialog_exe.linkSystemLibrary("vulkan");
        file_dialog_exe.linkSystemLibrary("wayland-client");
        file_dialog_exe.linkSystemLibrary("freetype");
        file_dialog_exe.linkSystemLibrary("harfbuzz");
        file_dialog_exe.linkSystemLibrary("fontconfig");
        file_dialog_exe.linkSystemLibrary("png");
        file_dialog_exe.linkSystemLibrary("dbus-1");
        file_dialog_exe.linkLibC();

        b.installArtifact(file_dialog_exe);

        const run_file_dialog_step = b.step("run-file-dialog", "Run the Linux file dialog demo");
        const run_file_dialog_cmd = b.addRunArtifact(file_dialog_exe);
        run_file_dialog_cmd.setCwd(b.path(".")); // Run from project root so assets/ can be found
        run_file_dialog_step.dependOn(&run_file_dialog_cmd.step);
        run_file_dialog_cmd.step.dependOn(b.getInstallStep());

        // =====================================================================
        // Tests
        // =====================================================================

        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        mod_tests.linkSystemLibrary("vulkan");
        mod_tests.linkSystemLibrary("wayland-client");
        mod_tests.linkSystemLibrary("freetype");
        mod_tests.linkSystemLibrary("harfbuzz");
        mod_tests.linkSystemLibrary("fontconfig");
        mod_tests.linkSystemLibrary("png");
        mod_tests.linkSystemLibrary("dbus-1");
        mod_tests.linkLibC();

        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
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
    gooey_wasm_module.addAnonymousImport("image_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/image.wgsl"),
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
    addWasmExample(b, gooey_wasm_module, wasm_target, "layout", "src/examples/layout.zig", "web/layout");
    addWasmExample(b, gooey_wasm_module, wasm_target, "select", "src/examples/select.zig", "web/select");
    addWasmExample(b, gooey_wasm_module, wasm_target, "text", "src/examples/text_debug_example.zig", "web/text");
    addWasmExample(b, gooey_wasm_module, wasm_target, "images", "src/examples/images_wasm.zig", "web/images");
    addWasmExample(b, gooey_wasm_module, wasm_target, "tooltip", "src/examples/tooltip.zig", "web/tooltip");
    addWasmExample(b, gooey_wasm_module, wasm_target, "modal", "src/examples/modal.zig", "web/modal");
    addWasmExample(b, gooey_wasm_module, wasm_target, "file-dialog", "src/examples/web_file_dialog.zig", "web/file-dialog");
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
