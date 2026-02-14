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
        // Gooey Charts Module
        // =========================================================================

        const charts_mod = b.addModule("gooey-charts", .{
            .root_source_file = b.path("charts/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        charts_mod.addImport("gooey", mod);

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
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "animation", "src/examples/animation.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "spaceship", "src/examples/spaceship.zig", true);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "glass", "src/examples/glass.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "window-features", "src/examples/window_features.zig", false);
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
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "tree-example", "src/examples/tree_example.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "a11y-demo", "src/examples/a11y_demo.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "accessible-form", "src/examples/accessible_form.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "form-validation", "src/examples/form_validation.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "drag-drop", "src/examples/drag_drop.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "canvas-demo", "src/examples/canvas_demo.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "canvas-drawing", "src/examples/canvas_drawing.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "lucide-demo", "src/examples/lucide_demo.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "new-api-demo", "src/examples/new_api_demo.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "code-editor", "src/examples/code_editor.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "multi-window", "src/examples/multi_window.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "ai-canvas-spike", "src/examples/ai_canvas_spike.zig", false);
        addNativeExample(b, mod, objc_dep.module("objc"), target, optimize, "ai-canvas", "src/examples/ai_canvas.zig", false);

        // =========================================================================
        // Charts Examples
        // =========================================================================

        addChartsExample(b, mod, charts_mod, objc_dep.module("objc"), target, optimize, "charts-demo", "src/examples/charts_demo.zig");
        addChartsExample(b, mod, charts_mod, objc_dep.module("objc"), target, optimize, "dashboard", "src/examples/dashboard.zig");

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

        // Charts tests
        const charts_tests = b.addTest(.{
            .root_module = charts_mod,
        });
        const run_charts_tests = b.addRunArtifact(charts_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_exe_tests.step);
        test_step.dependOn(&run_charts_tests.step);

        // =====================================================================
        // Layout Benchmarks
        // =====================================================================

        const bench_exe = b.addExecutable(.{
            .name = "layout-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/layout/benchmarks.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "gooey", .module = mod },
                },
            }),
        });

        const bench_step = b.step("bench", "Run layout engine benchmarks");
        const bench_run = b.addRunArtifact(bench_exe);
        bench_step.dependOn(&bench_run.step);

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
        // Automatically compiles shaders when GLSL sources change.
        // Writes directly to source tree so @embedFile can find them.
        // Requires glslc (from vulkan-tools, shaderc, or Vulkan SDK).
        //
        // Pre-compiled .spv files are checked into the repo, so this step
        // can be skipped in CI or when glslc is not available.
        //
        // Install glslc:
        //   Ubuntu/Debian: sudo apt install glslc
        //   Arch: sudo pacman -S shaderc
        //   Or install Vulkan SDK from https://vulkan.lunarg.com/

        // Option to skip shader compilation (useful for CI where glslc isn't available)
        const skip_shader_compile = b.option(bool, "skip-shader-compile", "Skip shader compilation (use pre-compiled .spv files)") orelse false;

        const compile_shaders_step = b.step("compile-shaders", "Compile GLSL shaders to SPIR-V (requires glslc)");

        if (!skip_shader_compile) {
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

            // Create shader compilation commands
            // Writes output directly to source tree for @embedFile compatibility
            inline for (shaders) |shader| {
                const compile_cmd = b.addSystemCommand(&.{
                    "glslc",
                    "-fshader-stage=" ++ shader.stage,
                    "-o",
                    shader_dir ++ "/" ++ shader.output,
                });
                // Track input file - triggers recompilation when source changes
                compile_cmd.addFileArg(b.path(shader_dir ++ "/" ++ shader.source));
                compile_shaders_step.dependOn(&compile_cmd.step);
            }
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
        linkLinuxLibraries(exe);

        b.installArtifact(exe);

        // Ensure shaders are compiled before building executables that @embedFile them
        // (only if shader compilation is enabled)
        if (!skip_shader_compile) {
            exe.step.dependOn(compile_shaders_step);
        }

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
        // Linux Native Examples
        // =========================================================================

        addLinuxExample(b, mod, target, optimize, compile_shaders_step, skip_shader_compile, "basic", "src/examples/linux_demo.zig");
        addLinuxExample(b, mod, target, optimize, compile_shaders_step, skip_shader_compile, "text", "src/examples/linux_text_demo.zig");
        addLinuxExample(b, mod, target, optimize, compile_shaders_step, skip_shader_compile, "file-dialog", "src/examples/linux_file_dialog.zig");
        addLinuxExample(b, mod, target, optimize, compile_shaders_step, skip_shader_compile, "drag-drop", "src/examples/drag_drop.zig");
        addLinuxExample(b, mod, target, optimize, compile_shaders_step, skip_shader_compile, "lucide-demo", "src/examples/lucide_demo.zig");

        // =====================================================================
        // Tests
        // =====================================================================

        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        linkLinuxLibraries(mod_tests);
        if (!skip_shader_compile) {
            mod_tests.step.dependOn(compile_shaders_step);
        }

        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);

        // =====================================================================
        // Valgrind Memory Leak Detection
        // =====================================================================
        // Valgrind doesn't support modern CPU instructions (AVX, SSE4.2, etc.)
        // so we need a separate test build with baseline CPU features.
        // We use native OS/arch but override just the CPU model to keep
        // system library search paths working.

        const valgrind_target = b.resolveTargetQuery(.{
            .cpu_model = .baseline, // No AVX/SSE4.2 - valgrind doesn't support them
        });

        // Create a valgrind-compatible module (baseline CPU, no fancy instructions)
        const valgrind_mod = b.addModule("gooey-valgrind", .{
            .root_source_file = b.path("src/root.zig"),
            .target = valgrind_target,
            .optimize = .ReleaseSafe, // ReleaseSafe for meaningful stack traces
        });

        // Separate test artifact for valgrind with baseline CPU
        const valgrind_tests = b.addTest(.{
            .root_module = valgrind_mod,
        });
        linkLinuxLibraries(valgrind_tests);
        if (!skip_shader_compile) {
            valgrind_tests.step.dependOn(compile_shaders_step);
        }

        const test_valgrind_step = b.step("test-valgrind", "Run tests under valgrind");
        const valgrind_run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--show-leak-kinds=definite,indirect,possible", // Exclude "still reachable" (not real leaks)
            "--errors-for-leak-kinds=definite,indirect,possible", // Only fail on actual leaks
            "--num-callers=15", // Enough for useful traces without noise
            "--error-exitcode=1",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--max-stackframe=4000000", // Zig's large stack frames for async/coroutines
        });
        valgrind_run.addArtifactArg(valgrind_tests);
        test_valgrind_step.dependOn(&valgrind_run.step);
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
    gooey_wasm_module.addAnonymousImport("path_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/path.wgsl"),
    });
    gooey_wasm_module.addAnonymousImport("solid_path_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/path_solid.wgsl"),
    });
    gooey_wasm_module.addAnonymousImport("polyline_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/polyline.wgsl"),
    });
    gooey_wasm_module.addAnonymousImport("point_cloud_wgsl", .{
        .root_source_file = b.path("src/platform/wgpu/shaders/point_cloud.wgsl"),
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
        // Increase stack size for large structs (Gooey is ~400KB with a11y)
        wasm_exe.stack_size = 1024 * 1024; // 1MB stack

        const wasm_step = b.step("wasm", "Build showcase for web (main demo)");
        wasm_step.dependOn(&b.addInstallArtifact(wasm_exe, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        }).step);
        wasm_step.dependOn(&b.addInstallFile(b.path("web/index.html"), "web/index.html").step);

        // Copy assets for WASM builds (images need to be fetched via URL)
        wasm_step.dependOn(&b.addInstallFile(b.path("assets/gooey-logo-final.png"), "web/assets/gooey-logo-final.png").step);
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
    addWasmExample(b, gooey_wasm_module, wasm_target, "drag-drop", "src/examples/drag_drop.zig", "web/drag-drop");
}

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

/// Helper to add a charts example with both gooey and gooey-charts modules.
fn addChartsExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    charts_module: *std.Build.Module,
    objc_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    source: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
                .{ .name = "gooey-charts", .module = charts_module },
                .{ .name = "objc", .module = objc_module },
            },
        }),
    });

    b.installArtifact(exe);

    const step_name = b.fmt("run-{s}", .{name});
    const step_desc = b.fmt("Run the {s} example", .{name});
    const step = b.step(step_name, step_desc);

    const run_cmd = b.addRunArtifact(exe);
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
    // Increase stack size for large structs (Gooey is ~400KB with a11y)
    exe.stack_size = 1024 * 1024; // 1MB stack

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

/// Helper to add a Linux native example with Vulkan + Wayland system libraries.
fn addLinuxExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compile_shaders_step: *std.Build.Step,
    skip_shader_compile: bool,
    name: []const u8,
    source: []const u8,
) void {
    const exe = b.addExecutable(.{
        .name = b.fmt("gooey-{s}", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
            },
        }),
    });

    linkLinuxLibraries(exe);

    b.installArtifact(exe);
    if (!skip_shader_compile) {
        exe.step.dependOn(compile_shaders_step);
    }

    const step_name = b.fmt("run-{s}", .{name});
    const step_desc = b.fmt("Run the {s} example", .{name});
    const step = b.step(step_name, step_desc);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path(".")); // Run from project root so assets/ can be found
    step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
}

/// Links the standard set of Linux system libraries (Vulkan, Wayland, text rendering, etc.)
fn linkLinuxLibraries(step: *std.Build.Step.Compile) void {
    step.linkSystemLibrary("vulkan");
    step.linkSystemLibrary("wayland-client");
    step.linkSystemLibrary("freetype");
    step.linkSystemLibrary("harfbuzz");
    step.linkSystemLibrary("fontconfig");
    step.linkSystemLibrary("png");
    step.linkSystemLibrary("dbus-1");
    step.linkLibC();
}
