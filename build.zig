const std = @import("std");

/// Linux display and renderer pair, selected with `-Dlinux-backend`.
/// Mirrored into the source tree through the `gooey_build_options` module
/// and read by `src/platform/linux_backend.zig`.
pub const LinuxBackend = enum {
    /// Wayland window, Vulkan GPU renderer (default).
    wayland_vulkan,
    /// Wayland window, CPU renderer presented through `wl_shm`.
    wayland_cpu,
    /// No display server: CPU renderer on `/dev/fb0`, evdev input.
    fbdev,
};

/// Text service behind `TextSystem`, mirrored into `gooey_build_options`.
/// `synthetic` derives every metric from the point size, so goldens match on
/// every host; only the goldens and core test roots select it.
pub const TextBackend = enum {
    /// CoreText, FreeType and HarfBuzz, DirectWrite, or the browser.
    platform,
    /// `src/text/backends/synthetic`: deterministic metrics, no font files.
    synthetic,
};

/// Windows renderer, selected with `-Dwindows-renderer`. Mirrored into
/// `gooey_build_options` and read by `src/platform/windows/renderer.zig`.
pub const WindowsRenderer = enum {
    /// The Vulkan renderer shared with Linux (default).
    vulkan,
    /// Direct3D 11, with WARP for machines without a hardware driver.
    dx11,
};

/// Frame trace scenario, selected with `-Dframe-trace` (`src/core/frame_trace.zig`).
/// Mirrored into `gooey_build_options` for app modules only; tests, goldens,
/// and benchmarks always build with `.off`.
pub const FrameTrace = enum {
    /// No trace: the shipped configuration.
    off,
    /// Record frames; the app or a person drives it.
    passive,
    /// Request a render every frame.
    redraw,
    /// Scroll at the window centre every frame.
    scroll,
    /// Click the window centre, then type and delete one key per frame.
    typing,
};

/// The `-Dframe-trace` and `-Dframe-trace-seconds` choices.
const FrameTraceChoice = struct {
    scenario: FrameTrace,
    seconds: u32,
};

const ExampleDefinition = struct {
    name: []const u8,
    source: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const frame_trace = FrameTraceChoice{
        .scenario = b.option(
            FrameTrace,
            "frame-trace",
            "Record per-frame phase times to frame-trace.csv: off (default), passive, " ++
                "redraw, scroll, or typing",
        ) orelse .off,
        .seconds = b.option(
            u32,
            "frame-trace-seconds",
            "Seconds a frame trace runs before it writes its file and quits (default 30)",
        ) orelse 30,
    };

    // Benchmark JSON output directory (optional).
    // Usage: zig build bench-all -Dbench-json-dir=bench-results
    const bench_json_dir = b.option([]const u8, "bench-json-dir", "Directory to write benchmark JSON results");

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench/json_writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Benchmark comparison threshold (optional, default 15%).
    // Usage: zig build bench-compare -Dbench-threshold=10 -- old.json new.json
    const bench_threshold = b.option(f64, "bench-threshold", "Regression threshold percent for bench-compare (default: 15)");

    // =========================================================================
    // Benchmark Comparison Tool (platform-independent)
    // =========================================================================

    const compare_exe = b.addExecutable(.{
        .name = "bench-compare",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench/compare.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });

    const compare_step = b.step("bench-compare", "Compare two benchmark JSON files for regressions");
    const compare_run = b.addRunArtifact(compare_exe);
    if (bench_threshold) |threshold| {
        var threshold_buf: [32]u8 = undefined;
        const threshold_str = std.fmt.bufPrint(&threshold_buf, "{d:.1}", .{threshold}) catch "15.0";
        compare_run.addArgs(&.{ "--threshold", threshold_str });
    }
    compare_run.addPassthruArgs();
    compare_step.dependOn(&compare_run.step);

    // =========================================================================
    // Frame Trace Report (platform-independent): `-Dframe-trace` summaries
    // =========================================================================

    const trace_report_exe = b.addExecutable(.{
        .name = "frame-trace-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/frame_trace_report.zig"),
            .target = target,
            .optimize = .fast,
        }),
    });
    const trace_report_run = b.addRunArtifact(trace_report_exe);
    trace_report_run.addPassthruArgs();
    b.step(
        "frame-trace-report",
        "Summarize -Dframe-trace files: zig build frame-trace-report -- frame-trace.csv",
    ).dependOn(&trace_report_run.step);
    const trace_report_tests = b.addTest(.{ .root_module = trace_report_exe.root_module });
    const run_trace_report_tests = b.addRunArtifact(trace_report_tests);

    // Unit tests for the comparison/gating logic itself.  Built here
    // (platform-independent) and wired into each branch's `test` step
    // below so CI actually exercises the regression gate's own rules.
    const compare_tests = b.addTest(.{
        .root_module = compare_exe.root_module,
    });
    const run_compare_tests = b.addRunArtifact(compare_tests);

    // Unit tests for the JSON writer + shared timing Sampler (the bench
    // module root). Wired into each branch's `test` step below so the
    // harness-facing schema and min/best-of-N accumulator are exercised in
    // CI without needing a macOS-only benchmark executable to run.
    const bench_tests = b.addTest(.{
        .root_module = bench_mod,
    });
    const run_bench_tests = b.addRunArtifact(bench_tests);

    // Platform detection
    const is_native_macos = target.result.os.tag == .macos;
    const is_native_linux = target.result.os.tag == .linux;
    const is_native_windows = target.result.os.tag == .windows;

    if (is_native_windows) addWindowsBuilds(b, target, optimize, frame_trace);

    if (is_native_macos) {
        // Local, zero-dependency Objective-C runtime wrapper (a trimmed in-tree
        // port of the subset of mitchellh/zig-objc that Gooey used). The system
        // `objc` library and `Foundation` framework — where these extern
        // symbols resolve — are linked here so the module is self-contained.
        const objc_mod = b.addModule("objc", .{
            .root_source_file = b.path("src/platform/macos/objc/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        objc_mod.linkSystemLibrary("objc", .{});
        objc_mod.linkFramework("Foundation", .{});

        // Create the gooey module
        const mod = b.addModule("gooey", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("objc", objc_mod);
        mod.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
            .frame_trace = frame_trace.scenario,
            .frame_trace_seconds = frame_trace.seconds,
        }));
        linkMacosFrameworks(mod);

        // Benchmarks measure the shipped configuration, so they import a
        // `gooey` built `.fast` regardless of `-Doptimize`. Safety checks are
        // emitted per owning module, so importing the default `mod` would time
        // Debug-checked library code even from a `.fast` benchmark root.
        const bench_gooey_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .fast,
        });
        bench_gooey_mod.addImport("objc", objc_mod);
        bench_gooey_mod.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{}));
        linkMacosFrameworks(bench_gooey_mod);

        // =========================================================================
        // Gooey Components Module
        // =========================================================================

        const components_mod = b.addModule("gooey-components", .{
            .root_source_file = b.path("components/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        components_mod.addImport("gooey", mod);

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
        // Native Mac Examples
        // =========================================================================

        const native_examples = [_]ExampleDefinition{
            .{ .name = "animation", .source = "src/examples/animation.zig" },
            .{ .name = "counter", .source = "src/examples/counter.zig" },
            .{ .name = "todo", .source = "src/examples/todo.zig" },
            .{ .name = "core-file-dialog", .source = "src/examples/core_file_dialog.zig" },
            .{ .name = "layout", .source = "src/examples/layout.zig" },
            .{ .name = "nested-overlay", .source = "src/examples/nested_overlay.zig" },
            .{ .name = "dynamic-counters", .source = "src/examples/dynamic_counters.zig" },
            .{ .name = "actions", .source = "src/examples/actions.zig" },
            .{ .name = "images", .source = "src/examples/images.zig" },
            .{ .name = "virtual-list", .source = "src/examples/virtual_list_example.zig" },
            .{ .name = "data-table", .source = "src/examples/data_table_example.zig" },
            .{ .name = "accessible-form", .source = "src/examples/accessible_form.zig" },
            .{ .name = "lucide-demo", .source = "src/examples/lucide_demo.zig" },
            .{ .name = "code-editor", .source = "src/examples/code_editor.zig" },
            .{ .name = "dashboard", .source = "src/examples/dashboard.zig" },
        };
        // `zig build run` runs todo, the default example (contract decision 15).
        var todo_exe: ?*std.Build.Step.Compile = null;
        for (native_examples) |example| {
            const example_exe = addNativeExample(
                b,
                mod,
                components_mod,
                charts_mod,
                objc_mod,
                target,
                optimize,
                example.name,
                example.source,
            );
            if (std.mem.eql(u8, example.name, "todo")) todo_exe = example_exe;
        }
        const exe = todo_exe.?;
        const run_step = b.step("run", "Run the todo example");
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.addPassthruArgs();
        run_cmd.step.dependOn(b.getInstallStep());
        run_step.dependOn(&run_cmd.step);

        // =====================================================================
        // Tests
        // =====================================================================

        const mod_tests = b.addTest(.{
            .root_module = mod,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const components_tests = b.addTest(.{
            .root_module = components_mod,
        });
        const run_components_tests = b.addRunArtifact(components_tests);

        const watcher_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/watcher.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        const run_watcher_tests = b.addRunArtifact(watcher_tests);

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
        test_step.dependOn(&run_components_tests.step);
        test_step.dependOn(&run_watcher_tests.step);
        test_step.dependOn(&run_exe_tests.step);
        addGoldens(b, target, optimize, .{ .objc = objc_mod }, test_step);
        test_step.dependOn(&run_charts_tests.step);
        test_step.dependOn(&run_compare_tests.step);
        test_step.dependOn(&run_bench_tests.step);
        test_step.dependOn(&run_trace_report_tests.step);

        addFuzz(b, mod, target, optimize, test_step);

        // =====================================================================
        // Layout Benchmarks
        // =====================================================================

        const bench_exe = b.addExecutable(.{
            .name = "layout-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/layout/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });

        const bench_step = b.step("bench", "Run layout engine benchmarks");
        const bench_run = b.addRunArtifact(bench_exe);
        if (bench_json_dir) |dir| {
            bench_run.addArgs(&.{ "--json-dir", dir });
        }
        bench_step.dependOn(&bench_run.step);

        // =====================================================================
        // Core Benchmarks
        // =====================================================================

        const core_bench_exe = b.addExecutable(.{
            .name = "core-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/core/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });

        const core_bench_step = b.step("bench-core", "Run core module benchmarks");
        const core_bench_run = b.addRunArtifact(core_bench_exe);
        if (bench_json_dir) |dir| {
            core_bench_run.addArgs(&.{ "--json-dir", dir });
        }
        core_bench_step.dependOn(&core_bench_run.step);

        // Core `validate:` tests, pack's included: they check that each
        // benchmark measures the output it claims, so wire them into `test`.
        const core_bench_tests = b.addTest(.{
            .root_module = core_bench_exe.root_module,
        });
        const run_core_bench_tests = b.addRunArtifact(core_bench_tests);
        test_step.dependOn(&run_core_bench_tests.step);

        // =====================================================================
        // Text Benchmarks
        // =====================================================================

        const text_bench_exe = b.addExecutable(.{
            .name = "text-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/text/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });

        const text_bench_step = b.step("bench-text", "Run text module benchmarks");
        const text_bench_run = b.addRunArtifact(text_bench_exe);
        if (bench_json_dir) |dir| {
            text_bench_run.addArgs(&.{ "--json-dir", dir });
        }
        text_bench_step.dependOn(&text_bench_run.step);

        _ = addFailFastChecks(b, mod, components_mod, target, optimize, test_step);
        addImportBan(b, test_step);

        // =====================================================================
        // Accessibility Benchmarks (per-frame fingerprint + tree diff)
        // =====================================================================

        const accessibility_bench_exe = b.addExecutable(.{
            .name = "accessibility-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/accessibility/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });

        const accessibility_bench_step = b.step("bench-accessibility", "Run accessibility module benchmarks");
        const accessibility_bench_run = b.addRunArtifact(accessibility_bench_exe);
        if (bench_json_dir) |dir| {
            accessibility_bench_run.addArgs(&.{ "--json-dir", dir });
        }
        accessibility_bench_step.dependOn(&accessibility_bench_run.step);

        // Accessibility `validate:` tests (the diff's dirty/removed counts) run
        // only in Debug — wire them into `test`.
        const accessibility_bench_tests = b.addTest(.{
            .root_module = accessibility_bench_exe.root_module,
        });
        const run_accessibility_bench_tests = b.addRunArtifact(accessibility_bench_tests);
        test_step.dependOn(&run_accessibility_bench_tests.step);

        // =====================================================================
        // Run All Benchmarks
        // =====================================================================

        const bench_all_step = b.step("bench-all", "Run all benchmark suites");
        bench_all_step.dependOn(&bench_run.step);
        bench_all_step.dependOn(&core_bench_run.step);
        bench_all_step.dependOn(&text_bench_run.step);
        bench_all_step.dependOn(&accessibility_bench_run.step);

        // =====================================================================
        // Hot Reload Watcher
        // =====================================================================

        const watcher_exe = b.addExecutable(.{
            .name = "gooey-hot",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/watcher.zig"),
                .target = target,
                .optimize = .debug,
            }),
        });

        b.installArtifact(watcher_exe);

        const hot_step = b.step("hot", "Run with hot reload");

        const watcher_cmd = b.addRunArtifact(watcher_exe);
        watcher_cmd.addArg("src");
        watcher_cmd.addArg("components/src");
        watcher_cmd.addArg("--");

        // Build scripts can no longer observe passthrough arguments, so the
        // watcher owns the default: a bare `zig build` becomes `zig build run`.
        watcher_cmd.addArg("zig");
        watcher_cmd.addArg("build");
        watcher_cmd.addPassthruArgs();

        hot_step.dependOn(&watcher_cmd.step);
    }

    // =============================================================================
    // Linux Native Builds (Vulkan + Wayland)
    // =============================================================================

    if (is_native_linux) {
        const linux_backend = b.option(
            LinuxBackend,
            "linux-backend",
            "Linux display/renderer: wayland_vulkan (default), wayland_cpu, or fbdev",
        ) orelse .wayland_vulkan;
        const gooey_options_mod = gooeyBuildOptionsModule(b, .{
            .linux_backend = linux_backend,
            .frame_trace = frame_trace.scenario,
            .frame_trace_seconds = frame_trace.seconds,
        });
        // Benchmarks and valgrind measure the shipped configuration.
        const untraced_options_mod = gooeyBuildOptionsModule(b, .{
            .linux_backend = linux_backend,
        });

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
        // Only the Vulkan renderer embeds SPIR-V, so CPU builds skip `glslc`.
        const skip_shader_compile = b.option(
            bool,
            "skip-shader-compile",
            "Skip shader compilation (use pre-compiled .spv files)",
        ) orelse (linux_backend != .wayland_vulkan);

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
                .{
                    .source = "triangles.vert",
                    .output = "triangles.vert.spv",
                    .stage = "vertex",
                },
                .{
                    .source = "strip_expanded.vert",
                    .output = "strip_expanded.vert.spv",
                    .stage = "vertex",
                },
                .{
                    .source = "point_instanced.vert",
                    .output = "point_instanced.vert.spv",
                    .stage = "vertex",
                },
                .{ .source = "mesh.frag", .output = "mesh.frag.spv", .stage = "fragment" },
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
                // Every stage shares the packed frame's layout; mesh stages also
                // share the anti-aliasing helpers.
                compile_cmd.addFileInput(b.path(shader_dir ++ "/packed.glsl"));
                compile_cmd.addFileInput(b.path(shader_dir ++ "/mesh.glsl"));
                compile_shaders_step.dependOn(&compile_cmd.step);
            }
        }

        // Create the gooey module for Linux
        const mod = b.addModule("gooey", .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        mod.addImport("gooey_build_options", gooey_options_mod);

        linkLinuxGooeyLibraries(mod, linux_backend);

        // Benchmarks measure the shipped configuration; see the macOS branch.
        const bench_gooey_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .fast,
        });
        bench_gooey_mod.addImport("gooey_build_options", untraced_options_mod);
        linkLinuxGooeyLibraries(bench_gooey_mod, linux_backend);

        // =========================================================================
        // Gooey Components Module
        // =========================================================================

        const components_mod = b.addModule("gooey-components", .{
            .root_source_file = b.path("components/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        components_mod.addImport("gooey", mod);

        const charts_mod = b.addModule("gooey-charts", .{
            .root_source_file = b.path("charts/src/root.zig"),
            .target = target,
            .optimize = optimize,
        });
        charts_mod.addImport("gooey", mod);

        // =========================================================================
        // Linux Native Examples
        // =========================================================================

        const linux_examples = [_]ExampleDefinition{
            .{ .name = "lucide-demo", .source = "src/examples/lucide_demo.zig" },
            .{ .name = "animation", .source = "src/examples/animation.zig" },
            .{ .name = "counter", .source = "src/examples/counter.zig" },
            .{ .name = "todo", .source = "src/examples/todo.zig" },
            .{ .name = "core-file-dialog", .source = "src/examples/core_file_dialog.zig" },
            .{ .name = "code-editor", .source = "src/examples/code_editor.zig" },
            .{ .name = "dynamic-counters", .source = "src/examples/dynamic_counters.zig" },
            .{ .name = "layout", .source = "src/examples/layout.zig" },
            .{ .name = "actions", .source = "src/examples/actions.zig" },
            .{ .name = "nested-overlay", .source = "src/examples/nested_overlay.zig" },
            .{ .name = "images", .source = "src/examples/images.zig" },
            .{ .name = "accessible-form", .source = "src/examples/accessible_form.zig" },
            .{ .name = "virtual-list", .source = "src/examples/virtual_list_example.zig" },
            .{ .name = "data-table", .source = "src/examples/data_table_example.zig" },
            .{ .name = "dashboard", .source = "src/examples/dashboard.zig" },
        };
        // `zig build run` runs todo, the default example (contract decision 15).
        var todo_install: ?*std.Build.Step.InstallArtifact = null;
        for (linux_examples) |example| {
            const install = addLinuxExample(
                b,
                mod,
                components_mod,
                charts_mod,
                target,
                optimize,
                compile_shaders_step,
                skip_shader_compile,
                linux_backend,
                example.name,
                example.source,
            );
            if (std.mem.eql(u8, example.name, "todo")) todo_install = install;
        }
        addLinuxDefaultSteps(b, todo_install.?);

        // =====================================================================
        // Layout Benchmarks
        // =====================================================================

        const bench_exe = b.addExecutable(.{
            .name = "layout-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/layout/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });
        linkLinuxLibraries(bench_exe, linux_backend);

        const bench_step = b.step("bench", "Run layout engine benchmarks");
        const bench_run = b.addRunArtifact(bench_exe);
        if (bench_json_dir) |dir| {
            bench_run.addArgs(&.{ "--json-dir", dir });
        }
        bench_step.dependOn(&bench_run.step);

        // =====================================================================
        // Core Benchmarks
        // =====================================================================

        const core_bench_exe = b.addExecutable(.{
            .name = "core-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/core/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });
        linkLinuxLibraries(core_bench_exe, linux_backend);

        const core_bench_step = b.step("bench-core", "Run core module benchmarks");
        const core_bench_run = b.addRunArtifact(core_bench_exe);
        if (bench_json_dir) |dir| {
            core_bench_run.addArgs(&.{ "--json-dir", dir });
        }
        core_bench_step.dependOn(&core_bench_run.step);

        // Core `validate:` tests, pack's included. The dependOn is added in
        // the Tests section below.
        const core_bench_tests = b.addTest(.{
            .root_module = core_bench_exe.root_module,
            .use_llvm = true,
        });
        linkLinuxLibraries(core_bench_tests, linux_backend);
        if (!skip_shader_compile) {
            core_bench_tests.step.dependOn(compile_shaders_step);
        }
        const run_core_bench_tests = b.addRunArtifact(core_bench_tests);

        // =====================================================================
        // Text Benchmarks
        // =====================================================================

        const text_bench_exe = b.addExecutable(.{
            .name = "text-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/text/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });
        linkLinuxLibraries(text_bench_exe, linux_backend);

        const text_bench_step = b.step("bench-text", "Run text module benchmarks");
        const text_bench_run = b.addRunArtifact(text_bench_exe);
        if (bench_json_dir) |dir| {
            text_bench_run.addArgs(&.{ "--json-dir", dir });
        }
        text_bench_step.dependOn(&text_bench_run.step);

        // =====================================================================
        // Accessibility Benchmarks (per-frame fingerprint + tree diff)
        // =====================================================================

        const accessibility_bench_exe = b.addExecutable(.{
            .name = "accessibility-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/accessibility/benchmarks.zig"),
                .target = target,
                .optimize = .fast,
                .imports = &.{
                    .{ .name = "gooey", .module = bench_gooey_mod },
                    .{ .name = "bench", .module = bench_mod },
                },
            }),
        });
        linkLinuxLibraries(accessibility_bench_exe, linux_backend);

        const accessibility_bench_step = b.step("bench-accessibility", "Run accessibility module benchmarks");
        const accessibility_bench_run = b.addRunArtifact(accessibility_bench_exe);
        if (bench_json_dir) |dir| {
            accessibility_bench_run.addArgs(&.{ "--json-dir", dir });
        }
        accessibility_bench_step.dependOn(&accessibility_bench_run.step);

        // Accessibility `validate:` tests run only in Debug. The dependOn is
        // added in the Tests section below.
        const accessibility_bench_tests = b.addTest(.{
            .root_module = accessibility_bench_exe.root_module,
            .use_llvm = true,
        });
        linkLinuxLibraries(accessibility_bench_tests, linux_backend);
        if (!skip_shader_compile) {
            accessibility_bench_tests.step.dependOn(compile_shaders_step);
        }
        const run_accessibility_bench_tests = b.addRunArtifact(accessibility_bench_tests);

        // =====================================================================
        // Run All Benchmarks
        // =====================================================================

        const bench_all_step = b.step("bench-all", "Run all benchmark suites");
        bench_all_step.dependOn(&bench_run.step);
        bench_all_step.dependOn(&core_bench_run.step);
        bench_all_step.dependOn(&text_bench_run.step);
        bench_all_step.dependOn(&accessibility_bench_run.step);

        // =====================================================================
        // Tests
        // =====================================================================

        const mod_tests = b.addTest(.{
            .root_module = mod,
            // Force the LLVM backend on Linux: the self-hosted x86_64 backend
            // in Zig 0.16 is the default for Debug builds but still segfaults
            // on larger test binaries (see 0.16.0 release notes — "inferior
            // machine code quality" and still-stabilizing). Using LLVM trades
            // a bit of compile time for a backend that actually completes.
            .use_llvm = true,
        });
        linkLinuxLibraries(mod_tests, linux_backend);
        if (!skip_shader_compile) {
            mod_tests.step.dependOn(compile_shaders_step);
        }

        const run_mod_tests = b.addRunArtifact(mod_tests);

        const components_tests = b.addTest(.{
            .root_module = components_mod,
            .use_llvm = true,
        });
        linkLinuxLibraries(components_tests, linux_backend);
        if (!skip_shader_compile) components_tests.step.dependOn(compile_shaders_step);
        const run_components_tests = b.addRunArtifact(components_tests);

        const charts_tests = b.addTest(.{ .root_module = charts_mod, .use_llvm = true });
        linkLinuxLibraries(charts_tests, linux_backend);
        if (!skip_shader_compile) charts_tests.step.dependOn(compile_shaders_step);
        const run_charts_tests = b.addRunArtifact(charts_tests);

        const watcher_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tools/watcher.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
            .use_llvm = true,
        });
        const run_watcher_tests = b.addRunArtifact(watcher_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_components_tests.step);
        test_step.dependOn(&run_charts_tests.step);
        test_step.dependOn(&run_watcher_tests.step);
        addGoldens(b, target, optimize, .{
            .linux_backend = linux_backend,
            .compile_dependency = if (skip_shader_compile) null else compile_shaders_step,
        }, test_step);
        test_step.dependOn(&run_compare_tests.step);
        test_step.dependOn(&run_bench_tests.step);
        test_step.dependOn(&run_trace_report_tests.step);
        test_step.dependOn(&run_core_bench_tests.step);
        test_step.dependOn(&run_accessibility_bench_tests.step);
        const fail_fast_exe = addFailFastChecks(
            b,
            mod,
            components_mod,
            target,
            optimize,
            test_step,
        );
        addImportBan(b, test_step);
        addFuzz(b, mod, target, optimize, test_step);
        linkLinuxLibraries(fail_fast_exe, linux_backend);
        if (!skip_shader_compile) {
            fail_fast_exe.step.dependOn(compile_shaders_step);
        }

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
            .optimize = .safe, // ReleaseSafe for meaningful stack traces
        });
        valgrind_mod.addImport("gooey_build_options", untraced_options_mod);

        // Separate test artifact for valgrind with baseline CPU
        const valgrind_tests = b.addTest(.{
            .root_module = valgrind_mod,
            // Force LLVM for the same reason as mod_tests above. Valgrind
            // also requires full DWARF, which the self-hosted backend does
            // not yet emit completely.
            .use_llvm = true,
        });
        linkLinuxLibraries(valgrind_tests, linux_backend);
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
            "--max-stackframe=4000000", // Zig's large stack frames for async/coroutines
        });
        valgrind_run.addFileArg2(b.path("valgrind.supp"), .{ .prefix = "--suppressions=" });
        valgrind_run.addArtifactArg(valgrind_tests);
        test_valgrind_step.dependOn(&valgrind_run.step);
    }

    addWasmBuilds(b, frame_trace);
    addLinuxTypecheck(b);
    addWindowsTypecheck(b);
    addMacosTypecheck(b);
}

// =============================================================================
// Windows Builds (Win32 + Vulkan)
// =============================================================================

/// Adds the Windows targets: the `gooey` and `gooey-components` modules, the
/// examples that run on Windows, and `test-windows` for the shared `root.zig`
/// tests plus the backend, DirectWrite, and WIC tests. See
/// `docs/windows-port.md`.
fn addWindowsBuilds(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    frame_trace: FrameTraceChoice,
) void {
    std.debug.assert(target.result.os.tag == .windows);
    std.debug.assert(target.result.cpu.arch == .x86_64);

    const windows_renderer = b.option(
        WindowsRenderer,
        "windows-renderer",
        "Windows renderer: vulkan (default) or dx11",
    ) orelse .vulkan;
    // Linked whichever renderer is selected: an import library adds a DLL
    // import only for symbols the binary references, so a DirectX 11 build
    // does not load `vulkan-1.dll`.
    const vulkan_import_library = addVulkanImportLibrary(b);
    const mod = b.addModule("gooey", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addObjectFile(vulkan_import_library);
    mod.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
        .windows_renderer = windows_renderer,
        .frame_trace = frame_trace.scenario,
        .frame_trace_seconds = frame_trace.seconds,
    }));
    addHlslCompile(b);

    const components_mod = b.addModule("gooey-components", .{
        .root_source_file = b.path("components/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    components_mod.addImport("gooey", mod);

    const charts_mod = b.addModule("gooey-charts", .{
        .root_source_file = b.path("charts/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    charts_mod.addImport("gooey", mod);

    const examples = [_]struct { name: []const u8, source: []const u8 }{
        // 0.4.0 core apps, on `platform/windows/core_host.zig`.
        .{ .name = "counter", .source = "src/examples/counter.zig" },
        .{ .name = "todo", .source = "src/examples/todo.zig" },
        .{ .name = "core-file-dialog", .source = "src/examples/core_file_dialog.zig" },
        .{ .name = "code-editor", .source = "src/examples/code_editor.zig" },
        .{ .name = "actions", .source = "src/examples/actions.zig" },
        .{ .name = "nested-overlay", .source = "src/examples/nested_overlay.zig" },
        .{ .name = "accessible-form", .source = "src/examples/accessible_form.zig" },
        .{ .name = "virtual-list", .source = "src/examples/virtual_list_example.zig" },
        .{ .name = "data-table", .source = "src/examples/data_table_example.zig" },
        .{ .name = "images", .source = "src/examples/images.zig" },
        .{ .name = "dashboard", .source = "src/examples/dashboard.zig" },
        .{ .name = "animation", .source = "src/examples/animation.zig" },
        .{ .name = "layout", .source = "src/examples/layout.zig" },
        .{ .name = "dynamic-counters", .source = "src/examples/dynamic_counters.zig" },
    };
    for (examples) |example| {
        addWindowsExample(
            b,
            mod,
            components_mod,
            charts_mod,
            target,
            optimize,
            example.name,
            example.source,
        );
    }

    // Two binaries, as on macOS and Linux: the shared tests run against the
    // same `gooey` module the examples link, so they see the Vulkan import
    // library. `windows_tests.zig` keeps the Windows-only set explicit rather
    // than relying on what `root.zig`'s discovery chain happens to reach.
    const shared_tests = b.addTest(.{ .root_module = mod });
    const backend_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    backend_tests.root_module.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
        .windows_renderer = windows_renderer,
    }));
    const step = b.step("test-windows", "Run the shared and Windows backend tests");
    step.dependOn(&b.addRunArtifact(shared_tests).step);
    step.dependOn(&b.addRunArtifact(backend_tests).step);
}

/// Adds a `gooey.App` example as `gooey-<name>.exe` and its `run-<name>` step.
fn addWindowsExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    components_module: *std.Build.Module,
    charts_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    name: []const u8,
    source: []const u8,
) void {
    std.debug.assert(name.len > 0);
    std.debug.assert(target.result.os.tag == .windows);

    const exe = b.addExecutable(.{
        .name = b.fmt("gooey-{s}", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
                .{ .name = "gooey-components", .module = components_module },
                .{ .name = "gooey-charts", .module = charts_module },
            },
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path(".")); // Run from the project root so assets/ can be found.
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(b.getInstallStep());
    b.step(b.fmt("run-{s}", .{name}), b.fmt("Run the {s} example", .{name}))
        .dependOn(&run_cmd.step);
}

/// Adds `zig build fuzz` for the layout fuzz targets in `src/layout/fuzz.zig`:
/// a single-shot smoke run, or `zig build fuzz -- --fuzz` for infinite mode.
/// `test` also runs the smoke pass, so the targets compile on every CI host
/// rather than rotting behind a step nothing runs.
fn addFuzz(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    test_step: *std.Build.Step,
) void {
    std.debug.assert(target.result.os.tag != .freestanding);
    std.debug.assert(test_step.owner == b);

    const fuzz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/layout/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
            },
        }),
    });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    run_fuzz.addPassthruArgs();
    const fuzz_step = b.step("fuzz", "Run layout-engine fuzz targets (pass --fuzz for infinite mode)");
    fuzz_step.dependOn(&run_fuzz.step);
    test_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
}

/// Generates `vulkan-1.lib`, the import library for the system Vulkan loader,
/// from `src/platform/windows/vulkan-1.def` with the bundled `zig dlltool`.
///
/// This is what lets a Windows build link Vulkan with only the loader that
/// GPU drivers install (`System32/vulkan-1.dll`), without the Vulkan SDK.
fn addVulkanImportLibrary(b: *std.Build) std.Build.LazyPath {
    const dlltool = b.addSystemCommand(&.{ b.graph.zig_exe, "dlltool", "-m", "i386:x86-64" });
    dlltool.addArg("-d");
    dlltool.addFileArg(b.path("src/platform/windows/vulkan-1.def"));
    dlltool.addArg("-l");
    return dlltool.addOutputFileArg("vulkan-1.lib");
}

/// Adds `compile-hlsl`: rewrites the DirectX 11 renderer's checked-in DXBC
/// from its HLSL with `src/tools/compile_hlsl.zig`, which calls the system
/// `D3DCompiler_47.dll`. Builds embed the checked-in files, so only a shader
/// edit needs this step, and only a Windows host can run it.
fn addHlslCompile(b: *std.Build) void {
    const step = b.step("compile-hlsl", "Compile the DirectX 11 HLSL shaders to DXBC");
    if (b.graph.host.result.os.tag != .windows) return;
    const exe = b.addExecutable(.{
        .name = "compile-hlsl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/compile_hlsl.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });
    const shader_dir = "src/platform/windows/shaders/";
    // Each entry point becomes `<source>.<entry>.dxbc`, which the renderer
    // embeds by that name.
    const shaders = [_]struct { source: []const u8, entry: []const u8, profile: []const u8 }{
        .{ .source = "quad", .entry = "vs_main", .profile = "vs_5_0" },
        .{ .source = "quad", .entry = "ps_main", .profile = "ps_5_0" },
        .{ .source = "sprite", .entry = "vs_main", .profile = "vs_5_0" },
        .{ .source = "sprite", .entry = "ps_glyph", .profile = "ps_5_0" },
        .{ .source = "sprite", .entry = "ps_svg", .profile = "ps_5_0" },
        .{ .source = "sprite", .entry = "ps_image", .profile = "ps_5_0" },
        .{ .source = "mesh", .entry = "vs_triangles", .profile = "vs_5_0" },
        .{ .source = "mesh", .entry = "vs_strip", .profile = "vs_5_0" },
        .{ .source = "mesh", .entry = "vs_points", .profile = "vs_5_0" },
        .{ .source = "mesh", .entry = "ps_mesh", .profile = "ps_5_0" },
        .{ .source = "upload", .entry = "vs_glyph", .profile = "vs_5_0" },
        .{ .source = "upload", .entry = "vs_svg", .profile = "vs_5_0" },
        .{ .source = "upload", .entry = "vs_image", .profile = "vs_5_0" },
        .{ .source = "upload", .entry = "ps_r8", .profile = "ps_5_0" },
        .{ .source = "upload", .entry = "ps_rgba8", .profile = "ps_5_0" },
    };
    for (shaders) |shader| {
        std.debug.assert(shader.entry.len > 3);
        const run = b.addRunArtifact(exe);
        run.setCwd(b.path("."));
        // The output is a source file Zig's cache does not track; always run.
        run.has_side_effects = true;
        run.addArgs(&.{
            b.fmt("{s}{s}.hlsl", .{ shader_dir, shader.source }),
            shader.entry,
            shader.profile,
            b.fmt("{s}{s}.{s}.dxbc", .{ shader_dir, shader.source, shader.entry }),
        });
        step.dependOn(&run.step);
    }
}

/// Adds `typecheck-windows`: semantic analysis of the Windows backend from
/// any host, with no linking, for the same reasons as `typecheck-linux`.
/// Every Win32 and Vulkan binding is a plain `extern`, so analysis needs no
/// SDK and no import library.
fn addWindowsTypecheck(b: *std.Build) void {
    const step = b.step(
        "typecheck-windows",
        "Semantically analyze the Windows backend from any host",
    );
    const windows_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    });
    std.debug.assert(windows_target.result.os.tag == .windows);
    // Each renderer selects different code in `platform/windows/window.zig`.
    for ([_]WindowsRenderer{ .vulkan, .dx11 }) |windows_renderer| {
        addWindowsTypecheckRoots(b, step, windows_target, windows_renderer);
    }
}

fn addWindowsTypecheckRoots(
    b: *std.Build,
    step: *std.Build.Step,
    windows_target: std.Build.ResolvedTarget,
    windows_renderer: WindowsRenderer,
) void {
    std.debug.assert(windows_target.result.os.tag == .windows);
    const options = gooeyBuildOptionsModule(b, .{ .windows_renderer = windows_renderer });
    const gooey_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = windows_target,
        .optimize = .debug,
    });
    gooey_mod.addImport("gooey_build_options", options);
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows_tests.zig"),
            .target = windows_target,
            .optimize = .debug,
            .imports = &.{.{ .name = "gooey_build_options", .module = options }},
        }),
    });
    // Every shared `test {}` block and the `refAllDecls` discovery chain, the
    // same coverage `typecheck-linux` gets from its `root.zig` test root.
    const shared_tests = b.addTest(.{ .root_module = gooey_mod });

    const components_mod = b.createModule(.{
        .root_source_file = b.path("components/src/root.zig"),
        .target = windows_target,
        .optimize = .debug,
        .imports = &.{.{ .name = "gooey", .module = gooey_mod }},
    });
    // The 0.4.0 core host: window binding, render thread, IME, clipboard,
    // file dialogs, and UI Automation.
    const core_app = b.addExecutable(.{
        .name = b.fmt("typecheck-windows-todo-{s}", .{@tagName(windows_renderer)}),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/examples/todo.zig"),
            .target = windows_target,
            .optimize = .debug,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_mod },
                .{ .name = "gooey-components", .module = components_mod },
            },
        }),
    });

    // Depend on the compile steps only; see `addLinuxTypecheckRoot`.
    step.dependOn(&tests.step);
    step.dependOn(&core_app.step);
    // The shared tests reach the renderer only through the window, which the
    // two roots above already analyze for this renderer; run them once.
    if (windows_renderer == .vulkan) step.dependOn(&shared_tests.step);
}

/// `typecheck-macos`: semantically analyze the macOS backend, its tests, and
/// the goldens from any host. Frameworks are not linked: extern declarations
/// need no library to type-check, and no binary is emitted.
fn addMacosTypecheck(b: *std.Build) void {
    const step = b.step("typecheck-macos", "Semantically analyze the macOS backend from any host");
    const macos_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .macos });
    std.debug.assert(macos_target.result.os.tag == .macos);

    const objc_mod = b.createModule(.{
        .root_source_file = b.path("src/platform/macos/objc/main.zig"),
        .target = macos_target,
        .optimize = .debug,
    });
    for ([_]TextBackend{ .platform, .synthetic }) |text_backend| {
        const gooey_mod = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = macos_target,
            .optimize = .debug,
            .link_libc = true,
        });
        gooey_mod.addImport("objc", objc_mod);
        gooey_mod.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
            .text_backend = text_backend,
        }));
        const tests = b.addTest(.{
            .name = b.fmt("typecheck-macos-{t}", .{text_backend}),
            .root_module = gooey_mod,
        });
        // Depend on the compile step only; see `addLinuxTypecheckRoot`.
        step.dependOn(&tests.step);
        if (text_backend == .platform) addMacosCoreExampleTypecheck(b, step, gooey_mod);
    }
}

/// The 0.4.0 core examples' `App.main` reaches the macOS host only from an
/// executable root, so analyze each as one. Nothing links: no binary is
/// requested.
fn addMacosCoreExampleTypecheck(
    b: *std.Build,
    step: *std.Build.Step,
    gooey_mod: *std.Build.Module,
) void {
    const target = gooey_mod.resolved_target.?;
    const components_mod = b.createModule(.{
        .root_source_file = b.path("components/src/root.zig"),
        .target = target,
        .optimize = .debug,
    });
    components_mod.addImport("gooey", gooey_mod);
    const charts_mod = b.createModule(.{
        .root_source_file = b.path("charts/src/root.zig"),
        .target = target,
        .optimize = .debug,
    });
    charts_mod.addImport("gooey", gooey_mod);
    const examples = [_][]const u8{
        "counter",
        "todo",
        "actions",
        "core_file_dialog",
        "nested_overlay",
        "virtual_list_example",
        "data_table_example",
        "dashboard",
        "lucide_demo",
        "images",
        "animation",
    };
    for (examples) |name| {
        const exe = b.addExecutable(.{
            .name = b.fmt("typecheck-macos-{s}", .{name}),
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("src/examples/{s}.zig", .{name})),
                .target = target,
                .optimize = .debug,
                .imports = &.{
                    .{ .name = "gooey", .module = gooey_mod },
                    .{ .name = "gooey-components", .module = components_mod },
                    .{ .name = "gooey-charts", .module = charts_mod },
                },
            }),
        });
        step.dependOn(&exe.step);
    }
}

// =============================================================================
// Public API for Consumers
// =============================================================================

/// Link all platform-specific system dependencies that Gooey requires.
///
/// Call this on your executable's compile step so the linker can find
/// the frameworks / shared libraries Gooey uses under the hood.
///
/// Example (consumer build.zig):
/// ```
/// const gooey_dep = b.dependency("gooey", .{ .target = target, .optimize = optimize });
/// const gooey_build = @import("gooey");
/// exe.root_module.addImport("gooey", gooey_dep.module("gooey"));
/// gooey_build.linkSystemDeps(exe);
/// ```
///
/// Note: The gooey *module* already declares its framework links, so in many
/// cases transitive linking handles everything automatically. This helper
/// exists as a safety net and for non-module usage patterns.
pub fn linkSystemDeps(step: *std.Build.Step.Compile) void {
    const mod = step.root_module;
    const os = step.rootModuleTarget().os.tag;

    if (os == .macos) {
        mod.linkFramework("AppKit", .{});
        mod.linkFramework("Foundation", .{});
        mod.linkFramework("Metal", .{});
        mod.linkFramework("QuartzCore", .{});
        mod.linkFramework("CoreFoundation", .{});
        mod.linkFramework("CoreText", .{});
        mod.linkFramework("CoreGraphics", .{});
        mod.link_libc = true;
    }

    // The default backend's libraries. Consumers selecting another
    // `linux-backend` get the right set transitively from the gooey module.
    if (os == .linux) {
        linkLinuxLibraries(step, .wayland_vulkan);
    }
}

fn addNativeExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    components_module: *std.Build.Module,
    charts_module: *std.Build.Module,
    objc_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
                .{ .name = "gooey-components", .module = components_module },
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
    run_cmd.addPassthruArgs();
    step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    return exe;
}

/// Adds `zig build import-ban` (`src/tools/import_ban.zig`), which fails when a
/// file or `@import` reaches a 0.3.1 path phase 6 deleted, and makes `test`
/// run it and its own tests. It reads the tree, so it runs on the host.
fn addImportBan(b: *std.Build, test_step: *std.Build.Step) void {
    const module = b.createModule(.{
        .root_source_file = b.path("src/tools/import_ban.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const exe = b.addExecutable(.{ .name = "import-ban", .root_module = module });
    const run = b.addRunArtifact(exe);
    run.setCwd(b.path("."));
    // The tree is the input, which Zig's cache cannot see, so run every time.
    run.has_side_effects = true;
    b.step("import-ban", "Fail on imports of deleted 0.3.1 paths").dependOn(&run.step);
    test_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

/// Adds the fail-fast checks for frame- and input-path failures to `test_step`.
///
/// Each mode of `src/testing/fail_fast_check.zig` drives one path that panics
/// instead of dropping work, and each run step asserts the abort and the named
/// message (CLAUDE.md §17, §24). A panic cannot be caught in-process, so every
/// mode runs in its own child process. Returns the executable so the caller can
/// add platform link steps.
fn addFailFastChecks(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    components_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "fail-fast-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/fail_fast_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
                .{ .name = "gooey-components", .module = components_module },
            },
        }),
    });

    const checks = [_]struct { mode: []const u8, stderr: []const u8 }{
        .{ .mode = "font-variant", .stderr = "TextSystem: font variant 'light' (font_id 4) " ++
            "is not loaded; FontLimits.variants loads 6 faces: regular, medium, semibold, bold, " ++
            "italic, bold_italic." },
        .{ .mode = "atlas-item", .stderr = "Atlas pool 'text' cannot hold one item: " ++
            "capacity 64x64 px, requested 65x6 px (1 px border included), frame 2." },
        .{ .mode = "atlas-live-set", .stderr = "Atlas pool 'svg' exhausted: capacity 64x64 px, " ++
            "64 rows held by items in use since frame 2, requested 64x16 px " ++
            "(1 px border included), frame 2." },
        .{ .mode = "core-allocation", .stderr = "allocation after initialization: alloc of " ++
            "16 bytes while the lifecycle is running" },
        .{ .mode = "core-duplicate-key", .stderr = "duplicate key \"twin\" under element" },
        .{ .mode = "core-opacity-range", .stderr = "Style.opacity 1.01 is outside 0 to 1" },
        .{ .mode = "core-grow-weight", .stderr = "Sizing.grow weight 0: a weight must be " ++
            "finite and greater than 0" },
        .{ .mode = "core-dialog-target", .stderr = "file dialog on_complete targets " ++
            "fail_fast_check.CoreApp.Stranger; the root state is fail_fast_check.CoreState" },
        .{ .mode = "core-dialog-paths", .stderr = "file dialog selected 17 paths: " ++
            "capacity 16. Raise ResourceLimits.events.dialog_path_count_max." },
        .{ .mode = "core-component-depth", .stderr = "component depth 65 exceeds " ++
            "build.component_depth_max 64 rendering fail_fast_check.CoreApp.Nest" },
        .{ .mode = "core-box-depth", .stderr = "build pool 'box depth' exhausted: capacity 63 " ++
            "levels inside the window root, 63 in use, 1 requested" },
        .{ .mode = "core-mono-unset", .stderr = "text uses family .mono, but no second " ++
            "family is loaded; set Config.fonts.mono and fonts.limits.mono_variants" },
        .{ .mode = "core-wrap-lines", .stderr = "text run of 1025 codepoints exceeds " ++
            "text.run_codepoint_count_max 1024, the longest run one shaping may hold in the " ++
            "262144-byte text scratch, in frame 1." },
        .{ .mode = "core-wrap-words", .stderr = "text run of 2049 codepoints exceeds " ++
            "text.run_codepoint_count_max 1024" },
        .{ .mode = "core-wrap-frame", .stderr = "wrapped lines exhausted: capacity 1024 " ++
            "(paint.glyph_count_frame_max), 1000 in use, 25 requested" },
        .{ .mode = "core-deinit-running", .stderr = "App.deinit on a running app: " ++
            "call App.stop first, before any teardown frees" },
        .{ .mode = "core-list-count", .stderr = "List \"rows\" of 65 rows: capacity 64. " ++
            "Raise fail_fast_check.CoreApp.TallRow.count_max." },
        .{ .mode = "core-mesh-points", .stderr = "mesh points exhausted: capacity 1024 " ++
            "(paint.polyline_point_count_frame_max), 0 in use, 1025 requested, frame 1." },
        .{ .mode = "core-image-requests", .stderr = "image loader pool 'requests' exhausted: " ++
            "capacity 4 images waiting or failed, 1 requested (\"assets/missing-4.png\") in " ++
            "frame 1. Raise ResourceLimits.atlas.image_request_count_max." },
        .{ .mode = "core-pack-polylines", .stderr = "Packed pool 'polylines' exhausted: " ++
            "capacity 4 (ResourceLimits.paint.polyline_count_frame_max), 4 in use, " ++
            "1 requested, frame 1." },
        .{ .mode = "core-pack-draws", .stderr = "Packed pool 'draws' exhausted: capacity 8 " ++
            "(ResourceLimits.records.paint_record_count_frame_max + 0), 8 in use, 1 requested, " ++
            "frame 1." },
        .{ .mode = "core-pack-clips", .stderr = "Packed pool 'clips' exhausted: capacity 9 " ++
            "(ResourceLimits.records.paint_record_count_frame_max + 1), 9 in use, 1 requested, " ++
            "frame 1." },
        .{ .mode = "core-capabilities-meshes", .stderr = "Packed frame 1 holds 1 meshes, but " ++
            "its renderer reports Capabilities.meshes = false." },
    };
    for (checks) |check| {
        const run = b.addRunArtifact(exe);
        run.addArg(check.mode);
        run.addCheck(.{ .expect_stderr_match = check.stderr });
        run.addCheck(.{ .expect_term = .{ .signal = .ABRT } });
        test_step.dependOn(&run.step);
    }
    return exe;
}

// =============================================================================
// Linux Type Checking (host-independent)
// =============================================================================

/// Absolute ceiling on the number of Linux typecheck roots. Each root is a
/// full semantic analysis of the Linux tree, so the count bounds both build
/// graph size and worst-case step wall time.
const typecheck_linux_root_count_max: usize = 8;

/// A single semantic-analysis root for the `typecheck-linux` step.
const TypecheckRoot = struct {
    /// Source file analyzed as the root module.
    source: []const u8,
    /// True when the root is the `gooey` library itself and must be analyzed
    /// as a test binary so `test {}` blocks are reachable; false when it is an
    /// example that imports `gooey` as a dependency.
    as_test: bool,
    /// Backend the root is analyzed for. Each non-default backend replaces a
    /// slice of `src/platform`, so each needs its own root to stay compiling.
    linux_backend: LinuxBackend = .wayland_vulkan,
    /// Embedded boards are mostly 64-bit Arm, so the framebuffer backend is
    /// also analyzed there to catch ABI-dependent `ioctl` and struct layouts.
    cpu_arch: std.Target.Cpu.Arch = .x86_64,
};

/// Adds the `typecheck-linux` step: full semantic analysis of the
/// Linux/Wayland/Vulkan backend from any host, with no linking.
///
/// Why this exists: `src/platform/linux/**` is only reachable by the compiler
/// when the target is Linux, so macOS development hosts (and any CI runner
/// without a Linux job) could not compile it at all, and Linux-only code could
/// only be reviewed by hand. Every Linux binding (`vulkan.zig`, `wayland.zig`,
/// `dbus.zig`, FreeType, libpng) is a plain `extern` declaration, so analysis
/// needs no C headers, no options, and no downloads.
///
/// The step is not wired into `install` or `test` because it re-analyzes the
/// whole library for a second target, which roughly doubles their wall time.
/// CI runs it as its own job.
///
/// No system libraries are linked. Library resolution happens *before*
/// semantic analysis, so a single `-lvulkan` would fail on a macOS host and
/// hide the errors this step exists to find. libc stays enabled because the
/// native Linux build links it, and analysis must see the same `std.c`
/// surface; Zig ships cross-compiling glibc stubs. Binary emission is
/// suppressed by never asking for the emitted binary: `std.Build.Step.Compile`
/// leaves `generated_bin` null until `getEmittedBin()` is called and then
/// passes `-fno-emit-bin` itself, so depending on the compile step alone gives
/// exact `-fno-emit-bin` semantics through the build API.
fn addLinuxTypecheck(b: *std.Build) void {
    const step = b.step(
        "typecheck-linux",
        "Semantically analyze the Linux backend from any host",
    );

    // `src/examples/todo.zig` reaches each backend's 0.4.0 core host: the
    // Wayland host with Vulkan and with the CPU renderer (window binding,
    // render thread, IME, dialogs), and the fbdev host (contract decision
    // 17). The `src/root.zig` test roots cover far more code: every `test {}`
    // block in the library, plus the `refAllDecls` discovery chain.
    const roots = [_]TypecheckRoot{
        .{ .source = "src/root.zig", .as_test = true },
        .{ .source = "src/examples/todo.zig", .as_test = false },
        .{
            .source = "src/examples/todo.zig",
            .as_test = false,
            .linux_backend = .wayland_cpu,
        },
        .{ .source = "src/root.zig", .as_test = true, .linux_backend = .fbdev },
        .{
            .source = "src/examples/todo.zig",
            .as_test = false,
            .linux_backend = .fbdev,
            .cpu_arch = .aarch64,
        },
    };
    comptime std.debug.assert(roots.len <= typecheck_linux_root_count_max);

    for (roots) |root| {
        const linux_target = b.resolveTargetQuery(.{
            .cpu_arch = root.cpu_arch,
            .os_tag = .linux,
            .abi = .gnu,
        });
        std.debug.assert(linux_target.result.os.tag == .linux);
        std.debug.assert(linux_target.result.cpu.arch == root.cpu_arch);
        addLinuxTypecheckRoot(b, step, linux_target, root);
    }
}

/// Analyzes one root for the Linux target. Split out so `addLinuxTypecheck`
/// keeps the root list, and this owns per-root module wiring.
fn addLinuxTypecheckRoot(
    b: *std.Build,
    step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    root: TypecheckRoot,
) void {
    std.debug.assert(root.source.len > 0);
    std.debug.assert(target.result.os.tag == .linux);

    const gooey_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .debug,
        .link_libc = true,
    });
    gooey_mod.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
        .linux_backend = root.linux_backend,
    }));

    const compile = if (root.as_test) b.addTest(.{
        .root_module = gooey_mod,
    }) else blk: {
        const components_mod = b.createModule(.{
            .root_source_file = b.path("components/src/root.zig"),
            .target = target,
            .optimize = .debug,
        });
        components_mod.addImport("gooey", gooey_mod);

        const root_mod = b.createModule(.{
            .root_source_file = b.path(root.source),
            .target = target,
            .optimize = .debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_mod },
                .{ .name = "gooey-components", .module = components_mod },
            },
        });

        break :blk b.addExecutable(.{
            .name = b.fmt("typecheck-linux-{s}-{t}-{t}", .{
                std.fs.path.stem(root.source),
                root.linux_backend,
                root.cpu_arch,
            }),
            .root_module = root_mod,
        });
    };

    // Depend on the compile step *only*. Installing it or calling
    // `getEmittedBin()` would populate `generated_bin` and re-enable linking.
    step.dependOn(&compile.step);
}

fn addWasmBuilds(b: *std.Build, frame_trace: FrameTraceChoice) void {
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const gooey_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = wasm_target,
        .optimize = .small,
    });
    addWasmShaderImports(b, gooey_module);
    gooey_module.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
        .frame_trace = frame_trace.scenario,
        .frame_trace_seconds = frame_trace.seconds,
    }));
    const components_module = b.createModule(.{
        .root_source_file = b.path("components/src/root.zig"),
        .target = wasm_target,
        .optimize = .small,
    });
    components_module.addImport("gooey", gooey_module);
    const charts_module = b.createModule(.{
        .root_source_file = b.path("charts/src/root.zig"),
        .target = wasm_target,
        .optimize = .small,
    });
    charts_module.addImport("gooey", gooey_module);
    const modules = WasmModules{
        .gooey = gooey_module,
        .components = components_module,
        .charts = charts_module,
    };

    std.debug.assert(wasm_target.result.cpu.arch == .wasm32);
    std.debug.assert(wasm_target.result.os.tag == .freestanding);

    addWasmExample(b, modules, wasm_target, .{
        .step_name = "wasm",
        .description = "Build the todo example for web",
        .source = "src/examples/todo.zig",
        .output_dir = "web",
    });
    addWasmExample(b, modules, wasm_target, .{
        .step_name = "wasm-counter",
        .description = "Build the counter example for web",
        .source = "src/examples/counter.zig",
        .output_dir = "web/counter",
    });
    // Any example for the web, for frame traces of the heavier examples:
    // `zig build wasm-example -Dwasm-example=src/examples/dashboard.zig`.
    const example_source = b.option(
        []const u8,
        "wasm-example",
        "Source of the example `wasm-example` builds into web/example (default: todo)",
    ) orelse "src/examples/todo.zig";
    addWasmExample(b, modules, wasm_target, .{
        .step_name = "wasm-example",
        .description = "Build the -Dwasm-example example for web into web/example",
        .source = example_source,
        .output_dir = "web/example",
    });
}

const WasmModules = struct {
    gooey: *std.Build.Module,
    components: *std.Build.Module,
    charts: *std.Build.Module,
};

fn addWasmShaderImports(b: *std.Build, module: *std.Build.Module) void {
    // The WebGPU renderer's one shader module (`src/platform/web/renderer.zig`).
    const path = "src/platform/wgpu/shaders/packed.wgsl";
    std.debug.assert(std.mem.endsWith(u8, path, ".wgsl"));
    module.addAnonymousImport("packed_wgsl", .{ .root_source_file = b.path(path) });
}

fn addWasmExample(
    b: *std.Build,
    modules: WasmModules,
    wasm_target: std.Build.ResolvedTarget,
    options: struct {
        step_name: []const u8,
        description: []const u8,
        source: []const u8,
        output_dir: []const u8,
    },
) void {
    std.debug.assert(options.step_name.len > 0);
    std.debug.assert(options.output_dir.len > 0);

    const application_module = b.createModule(.{
        .root_source_file = b.path(options.source),
        .target = wasm_target,
        .optimize = .small,
        .imports = &.{
            .{ .name = "gooey", .module = modules.gooey },
            .{ .name = "gooey-components", .module = modules.components },
            .{ .name = "gooey-charts", .module = modules.charts },
        },
    });
    const executable = b.addExecutable(.{
        .name = "app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/platform/web/entry.zig"),
            .target = wasm_target,
            .optimize = .small,
            .imports = &.{
                .{ .name = "application", .module = application_module },
                .{ .name = "gooey", .module = modules.gooey },
            },
        }),
    });
    executable.entry = .disabled;
    executable.rdynamic = true;
    executable.stack_size = 1024 * 1024;

    const step = b.step(options.step_name, options.description);
    step.dependOn(&b.addInstallArtifact(executable, .{
        .dest_dir = .{ .override = .{ .custom = options.output_dir } },
    }).step);
    step.dependOn(&b.addInstallFile(
        b.path("web/index.html"),
        b.fmt("{s}/index.html", .{options.output_dir}),
    ).step);
}

/// Helper to add a Linux native example with Vulkan + Wayland system libraries.
fn addLinuxExample(
    b: *std.Build,
    gooey_module: *std.Build.Module,
    components_module: *std.Build.Module,
    charts_module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    compile_shaders_step: *std.Build.Step,
    skip_shader_compile: bool,
    linux_backend: LinuxBackend,
    name: []const u8,
    source: []const u8,
) *std.Build.Step.InstallArtifact {
    const exe = b.addExecutable(.{
        .name = b.fmt("gooey-{s}", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gooey", .module = gooey_module },
                .{ .name = "gooey-components", .module = components_module },
                .{ .name = "gooey-charts", .module = charts_module },
            },
        }),
    });

    linkLinuxLibraries(exe, linux_backend);

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
    if (!skip_shader_compile) {
        exe.step.dependOn(compile_shaders_step);
    }

    const step_name = b.fmt("run-{s}", .{name});
    const step_desc = b.fmt("Run the {s} example", .{name});
    const step = b.step(step_name, step_desc);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.setCwd(b.path(".")); // Run from project root so assets/ can be found
    run_cmd.addPassthruArgs();
    step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    return install;
}

/// `zig build run` runs the todo example, and `zig build todo` installs only
/// its binary so previews stay focused. Every Linux backend builds it.
fn addLinuxDefaultSteps(b: *std.Build, install: *std.Build.Step.InstallArtifact) void {
    const run_step = b.step("run", "Run the todo example");
    const todo_step = b.step("todo", "Build only the todo example");
    todo_step.dependOn(&install.step);
    const run_cmd = b.addRunArtifact(install.artifact);
    run_cmd.setCwd(b.path(".")); // Run from the project root so assets/ can be found.
    run_cmd.addPassthruArgs();
    run_cmd.step.dependOn(&install.step);
    run_step.dependOn(&run_cmd.step);
}

/// Links the macOS frameworks the `gooey` module needs (tests included).
fn linkMacosFrameworks(mod: *std.Build.Module) void {
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkFramework("CoreText", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.link_libc = true;
}

/// Links the Linux system libraries the `gooey` module needs: Vulkan (plain
/// extern bindings, so no headers) and Wayland for the selected backend,
/// FreeType/HarfBuzz/Fontconfig for text, libpng for images, and D-Bus for
/// XDG portal file dialogs and accessibility.
fn linkLinuxGooeyLibraries(mod: *std.Build.Module, linux_backend: LinuxBackend) void {
    linkLinuxBackendLibraries(mod, linux_backend);
    mod.linkSystemLibrary("freetype", .{});
    mod.linkSystemLibrary("harfbuzz", .{});
    mod.linkSystemLibrary("fontconfig", .{});
    mod.linkSystemLibrary("png", .{});
    mod.linkSystemLibrary("dbus-1", .{});
    mod.link_libc = true;
}

/// Links the standard set of Linux system libraries (Vulkan, Wayland, text rendering, etc.)
fn linkLinuxLibraries(step: *std.Build.Step.Compile, linux_backend: LinuxBackend) void {
    const mod = step.root_module;
    linkLinuxBackendLibraries(mod, linux_backend);
    mod.linkSystemLibrary("freetype", .{});
    mod.linkSystemLibrary("harfbuzz", .{});
    mod.linkSystemLibrary("fontconfig", .{});
    mod.linkSystemLibrary("png", .{});
    mod.linkSystemLibrary("dbus-1", .{});
    mod.link_libc = true;
}

/// Libraries that differ by backend. A CPU build never links Vulkan, and the
/// fbdev build links no display-server library at all, so an embedded image
/// needs neither installed.
fn linkLinuxBackendLibraries(mod: *std.Build.Module, linux_backend: LinuxBackend) void {
    switch (linux_backend) {
        .wayland_vulkan => {
            mod.linkSystemLibrary("vulkan", .{});
            linkWaylandLibraries(mod);
        },
        .wayland_cpu => linkWaylandLibraries(mod),
        .fbdev => {},
    }
}

/// The Wayland client library, plus libwayland-cursor for the XCursor theme fallback on
/// compositors without `wp_cursor_shape_v1`.
fn linkWaylandLibraries(mod: *std.Build.Module) void {
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("wayland-cursor", .{});
}

/// Platform wiring the goldens' `gooey` module needs on the host target.
const GoldensWiring = struct {
    /// The Objective-C runtime module on macOS.
    objc: ?*std.Build.Module = null,
    /// The Linux backend whose libraries to link on Linux.
    linux_backend: ?LinuxBackend = null,
    /// A step the compile must wait for (Linux shader compilation).
    compile_dependency: ?*std.Build.Step = null,
};

/// Goldens (`src/testing/goldens/`): a `gooey` module built with the synthetic
/// text backend, so paint records match on every host. Adds the golden checks
/// to `test_step` and a `goldens` step that rewrites the golden files.
fn addGoldens(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    wiring: GoldensWiring,
    test_step: *std.Build.Step,
) void {
    const gooey_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    gooey_mod.addImport("gooey_build_options", gooeyBuildOptionsModule(b, .{
        .linux_backend = wiring.linux_backend orelse .wayland_vulkan,
        .text_backend = .synthetic,
    }));
    if (wiring.objc) |objc_mod| {
        gooey_mod.addImport("objc", objc_mod);
        linkMacosFrameworks(gooey_mod);
    }
    if (wiring.linux_backend) |linux_backend| linkLinuxGooeyLibraries(gooey_mod, linux_backend);

    const components_mod = b.createModule(.{
        .root_source_file = b.path("components/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gooey", .module = gooey_mod }},
    });
    const example_imports: []const std.Build.Module.Import = &.{
        .{ .name = "gooey", .module = gooey_mod },
        .{ .name = "gooey-components", .module = components_mod },
    };
    const counter_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/counter.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const todo_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/todo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const actions_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/actions.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const accessible_form_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/accessible_form.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const code_editor_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/code_editor.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const nested_overlay_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/nested_overlay.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const virtual_list_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/virtual_list_example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const data_table_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/data_table_example.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const charts_mod = b.createModule(.{
        .root_source_file = b.path("charts/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gooey", .module = gooey_mod }},
    });
    const dashboard_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/dashboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "gooey", .module = gooey_mod },
            .{ .name = "gooey-charts", .module = charts_mod },
        },
    });
    const lucide_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/lucide_demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const images_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/images.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const animation_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/animation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const dynamic_counters_mod = b.createModule(.{
        .root_source_file = b.path("src/examples/dynamic_counters.zig"),
        .target = target,
        .optimize = optimize,
        .imports = example_imports,
    });
    const goldens_imports: []const std.Build.Module.Import = &.{
        .{ .name = "accessible_form_example", .module = accessible_form_mod },
        .{ .name = "actions_example", .module = actions_mod },
        .{ .name = "animation_example", .module = animation_mod },
        .{ .name = "code_editor_example", .module = code_editor_mod },
        .{ .name = "data_table_example", .module = data_table_mod },
        .{ .name = "dashboard_example", .module = dashboard_mod },
        .{ .name = "dynamic_counters_example", .module = dynamic_counters_mod },
        .{ .name = "gooey", .module = gooey_mod },
        .{ .name = "gooey-components", .module = components_mod },
        .{ .name = "counter_example", .module = counter_mod },
        .{ .name = "images_example", .module = images_mod },
        .{ .name = "lucide_example", .module = lucide_mod },
        .{ .name = "nested_overlay_example", .module = nested_overlay_mod },
        .{ .name = "todo_example", .module = todo_mod },
        .{ .name = "virtual_list_example", .module = virtual_list_mod },
    };

    const tests = b.addTest(.{
        .name = "goldens-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/goldens/goldens_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = goldens_imports,
        }),
    });
    const capture = b.addExecutable(.{
        .name = "goldens-capture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testing/goldens/capture.zig"),
            .target = target,
            .optimize = optimize,
            .imports = goldens_imports,
        }),
    });
    if (wiring.compile_dependency) |dependency| {
        tests.step.dependOn(dependency);
        capture.step.dependOn(dependency);
    }
    const run_tests = b.addRunArtifact(tests);
    // The images check decodes `assets/` files relative to the project root.
    run_tests.setCwd(b.path("."));
    test_step.dependOn(&run_tests.step);

    const run_capture = b.addRunArtifact(capture);
    run_capture.setCwd(b.path("."));
    b.step("goldens", "Rewrite the golden files in src/testing/goldens").dependOn(&run_capture.step);
}

/// Build-time choices mirrored into `gooey_build_options`. Defaults are the
/// shipped configuration; `linux_backend` is read only on Linux targets and
/// `windows_renderer` only on Windows targets.
const GooeyBuildOptions = struct {
    linux_backend: LinuxBackend = .wayland_vulkan,
    text_backend: TextBackend = .platform,
    windows_renderer: WindowsRenderer = .vulkan,
    frame_trace: FrameTrace = .off,
    frame_trace_seconds: u32 = 30,
};

/// The `gooey_build_options` module: build-time choices the source tree reads
/// at comptime. Every module rooted at `src/root.zig` must import it.
fn gooeyBuildOptionsModule(b: *std.Build, choices: GooeyBuildOptions) *std.Build.Module {
    const options = b.addOptions();
    options.addOption(LinuxBackend, "linux_backend", choices.linux_backend);
    options.addOption(TextBackend, "text_backend", choices.text_backend);
    options.addOption(WindowsRenderer, "windows_renderer", choices.windows_renderer);
    options.addOption(FrameTrace, "frame_trace", choices.frame_trace);
    options.addOption(u32, "frame_trace_seconds", choices.frame_trace_seconds);
    return options.createModule();
}
