//! Child-process checks for frame- and input-path failures that panic (CLAUDE.md §2, §17).
//!
//! Each mode drives one path that used to drop work silently and now panics with the
//! pool, capacity, and counts. A panic cannot be caught inside a test, so the `test`
//! build step runs this program once per mode and asserts that it aborts with the
//! documented message (see `addFailFastChecks` in `build.zig`). Capacity modes fill the
//! pool exactly and claim one more. No mode may reach the end of `main`.
//!
//! Modes (first argument):
//! - `font-variant`: measures text in a font variant the face set did not load.
//! - `atlas-item`: inserts one item larger than its fixed atlas.
//! - `atlas-live-set`: fills an atlas with items used this frame and inserts one more.
//! - `core-allocation`: allocates through the 0.4.0 core's lifecycle guard after init.
//! - `core-duplicate-key`: renders two boxes with one key under one parent.
//! - `core-component-depth`: nests components one level past `component_depth_max`.
//! - `core-box-depth`: nests boxes one level past the 63 the window root's
//!   open stack holds inside it. The layout passes take every depth the stack
//!   admits, so the build's own check is the one that stops it.
//! - `core-opacity-range`: a box whose `Style.opacity` is just above 1.
//! - `core-grow-weight`: a box that grows with a weight of 0.
//! - `core-pointer-drag-unkeyed`: a box with `on_pointer_drag` and no key.
//! - `core-dialog-target`: names a non-root state as a file dialog's completion handler.
//! - `core-dialog-paths`: a dialog selects one path more than `dialog_path_count_max`.
//! - `core-mono-unset`: draws `.family = .mono` text in an app with no `fonts.mono`.
//! - `core-wrap-lines`: one text of a line past `MAX_LINES_PER_TEXT`. Layout
//!   measures it whole first, so the per-run shaping bound
//!   (`text.run_codepoint_count_max`) stops it, on every platform.
//! - `core-wrap-words`: one text of a word past `MAX_WORDS_PER_TEXT`, which
//!   the same bound stops first.
//! - `core-wrap-frame`: wraps two texts into one line past the frame's glyph budget.
//! - `core-deinit-running`: frees a running app without stopping it first.
//! - `core-list-count`: a `List` of per-row heights one row past its `count_max`.
//! - `core-mesh-points`: a polyline one point past `nano`'s polyline point limit.
//! - `core-image-requests`: one more image path than `nano`'s image request entries.
//! - `core-pack-polylines`: one polyline more than `nano`'s polyline limit, which
//!   pack checks: emit bounds only their points.
//! - `core-pack-draws`: packs nine records that each start a draw into a packed
//!   frame reserved for eight paint records.
//! - `core-pack-clips`: packs nine clip pushes into the same frame, one past its
//!   nine clips (eight plus the unbounded clip).
//! - `core-capabilities-meshes`: checks a frame holding a polyline against a
//!   renderer that reports no mesh support.

const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");

const Mode = enum {
    @"font-variant",
    @"atlas-item",
    @"atlas-live-set",
    @"core-allocation",
    @"core-duplicate-key",
    @"core-component-depth",
    @"core-box-depth",
    @"core-opacity-range",
    @"core-grow-weight",
    @"core-pointer-drag-unkeyed",
    @"core-dialog-target",
    @"core-dialog-paths",
    @"core-mono-unset",
    @"core-wrap-lines",
    @"core-wrap-words",
    @"core-wrap-frame",
    @"core-deinit-running",
    @"core-list-count",
    @"core-mesh-points",
    @"core-image-requests",
    @"core-pack-polylines",
    @"core-pack-draws",
    @"core-pack-clips",
    @"core-capabilities-meshes",
};

pub fn main(init: std.process.Init) !void {
    const args = init.minimal.args.vector;
    std.debug.assert(args.len == 2);

    const mode = std.meta.stringToEnum(Mode, std.mem.span(args[1])) orelse
        return error.UnknownMode;
    switch (mode) {
        .@"font-variant" => fontVariant(init.gpa, init.io),
        .@"atlas-item" => atlasItem(init.gpa, init.io),
        .@"atlas-live-set" => atlasLiveSet(init.gpa, init.io),
        .@"core-allocation" => coreAllocation(init.gpa, init.io),
        .@"core-duplicate-key" => coreTick(init.gpa, init.io, CoreApp.duplicateKey),
        .@"core-component-depth" => coreTick(init.gpa, init.io, CoreApp.nested),
        .@"core-box-depth" => coreTick(init.gpa, init.io, CoreApp.deepBoxes),
        .@"core-opacity-range" => coreTick(init.gpa, init.io, CoreApp.opacityRange),
        .@"core-grow-weight" => coreTick(init.gpa, init.io, CoreApp.growWeight),
        .@"core-pointer-drag-unkeyed" => coreTick(init.gpa, init.io, CoreApp.unkeyedDrag),
        .@"core-dialog-target" => coreDialogTarget(init.gpa, init.io),
        .@"core-dialog-paths" => coreDialogPaths(init.gpa, init.io),
        .@"core-mono-unset" => coreTick(init.gpa, init.io, CoreApp.monoText),
        .@"core-wrap-lines" => coreTick(init.gpa, init.io, CoreApp.wrapLines),
        .@"core-wrap-words" => coreTick(init.gpa, init.io, CoreApp.wrapWords),
        .@"core-wrap-frame" => coreTick(init.gpa, init.io, CoreApp.wrapFrame),
        .@"core-deinit-running" => coreDeinitRunning(init.gpa, init.io),
        .@"core-list-count" => coreTick(init.gpa, init.io, CoreApp.longList),
        .@"core-mesh-points" => coreTick(init.gpa, init.io, CoreApp.longPolyline),
        .@"core-image-requests" => coreTick(init.gpa, init.io, CoreApp.manyImages),
        .@"core-pack-polylines" => coreTick(init.gpa, init.io, CoreApp.manyPolylines),
        .@"core-pack-draws" => corePackRecords(init.gpa, .draws),
        .@"core-pack-clips" => corePackRecords(init.gpa, .clips),
        .@"core-capabilities-meshes" => coreCapabilitiesMeshes(init.gpa),
    }
    std.debug.print("unreachable: {s} did not panic\n", .{@tagName(mode)});
}

fn fontVariant(gpa: std.mem.Allocator, io: std.Io) void {
    // The standard set loads regular, medium, semibold, bold, italic, and bold
    // italic. Light is a valid variant that the set omits, so measuring it must
    // name the variant and the loaded set instead of substituting another face.
    const text = gooey.text;
    const text_system = gpa.create(text.TextSystem) catch |err| {
        std.debug.panic("setup: TextSystem allocation failed: {s}", .{@errorName(err)});
    };
    const uploads = gpa.create(text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    uploads.initHeadless(gpa, io) catch |err| {
        std.debug.panic("setup: AtlasUploads.initHeadless failed: {s}", .{@errorName(err)});
    };
    const atlas_options: text.AtlasOptions = .{ .size = 1024, .uploads = uploads };
    text_system.initInPlace(gpa, 1.0, io, &text.FontLimits.standard, atlas_options) catch |err| {
        std.debug.panic("setup: TextSystem.initInPlace failed: {s}", .{@errorName(err)});
    };
    text_system.loadSystemFont(.sans_serif, 16) catch |err| {
        std.debug.panic("setup: loadSystemFont failed: {s}", .{@errorName(err)});
    };
    _ = text_system.measureText(.app, "Total", .light) catch |err| {
        std.debug.panic("measureText failed instead of panicking: {s}", .{@errorName(err)});
    };
}

/// A 64² CPU-texture atlas of `kind` over its own journal, at frame 2.
fn atlasHarness(gpa: std.mem.Allocator, io: std.Io, kind: gooey.text.AtlasKind) *gooey.text.Atlas {
    const text = gooey.text;
    const uploads = gpa.create(text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    uploads.init(gpa, io, .{ .storage = .cpu_texture, .upload_bytes_frame_max = 64 }) catch |err| {
        std.debug.panic("setup: AtlasUploads.init failed: {s}", .{@errorName(err)});
    };
    const atlas = gpa.create(text.Atlas) catch |err| {
        std.debug.panic("setup: Atlas allocation failed: {s}", .{@errorName(err)});
    };
    atlas.init(gpa, .{ .kind = kind, .size = 64, .uploads = uploads }) catch |err| {
        std.debug.panic("setup: Atlas.init failed: {s}", .{@errorName(err)});
    };
    const frame = uploads.beginFrame(1);
    std.debug.assert(frame == 2);
    return atlas;
}

fn atlasItem(gpa: std.mem.Allocator, io: std.Io) void {
    // 63 px fits a 64 px atlas only without its 1 px border on each side.
    const atlas = atlasHarness(gpa, io, .text);
    var pixels: [63 * 4]u8 = @splat(1);
    _ = atlas.insert(63, 4, &pixels);
}

fn atlasLiveSet(gpa: std.mem.Allocator, io: std.Io) void {
    // Four 62×14 icons fill the four 16-row shelves exactly, all in frame 2;
    // none may be evicted for a fifth in the same frame.
    const atlas = atlasHarness(gpa, io, .svg);
    var pixels: [62 * 14 * 4]u8 = @splat(1);
    var index: u32 = 0;
    while (index < 4) : (index += 1) {
        std.debug.assert(atlas.insert(62, 14, &pixels) != null);
    }
    std.debug.assert(atlas.rows_active == 64);
    _ = atlas.insert(62, 14, &pixels);
}

// =============================================================================
// 0.4.0 core
// =============================================================================

const CoreState = struct {
    fn picked(_: *CoreState) void {}
    fn dragged(_: *CoreState) void {}
};

const core_config: gooey.Config(CoreState) = .{
    .title = "fail-fast",
    .width = 100,
    .height = 100,
    .limits = .nano,
};

const CoreApp = struct {
    fn empty(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{}, .{}));
    }

    fn duplicateKey(cx: *gooey.Cx) void {
        cx.render(.{
            gooey.ui.box(.{ .key = .{ .name = "twin" } }, .{}),
            gooey.ui.box(.{ .key = .{ .name = "twin" } }, .{}),
        });
    }

    /// One past the top of the valid range: 1 itself is fine.
    fn opacityRange(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .opacity = 1.01 } }, .{}));
    }

    /// A capture finds its box by id across frames, so it must be keyed.
    fn unkeyedDrag(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .on_pointer_drag = cx.on(CoreState.dragged, .{}),
            .style = .{ .source = @src() },
        }, .{}));
    }

    /// The smallest invalid weight; any positive weight is valid.
    fn growWeight(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .width = .{ .grow = 0 } } }, .{}));
    }

    /// Each level renders the next through `cx.render`, so the depth grows
    /// by one per level until the budget stops it.
    const Nest = struct {
        pub fn render(self: Nest, cx: *gooey.Cx) void {
            cx.render(self);
        }
    };

    fn nested(cx: *gooey.Cx) void {
        cx.render(Nest{});
    }

    /// 64 nested boxes: one more than fit inside the window root.
    fn deepBoxes(cx: *gooey.Cx) void {
        const box_count = gooey.internals.window.box_depth_max;
        cx.render(NestBoxes{ .remaining = box_count });
    }

    /// Opens two boxes per component level, so 64 boxes stay within the
    /// component depth budget and the box depth is the one exhausted.
    const NestBoxes = struct {
        remaining: u32,

        pub fn render(self: NestBoxes, cx: *gooey.Cx) void {
            std.debug.assert(self.remaining > 0);
            const pad: gooey.ui.Style = .{ .padding = .all(1) };
            if (self.remaining == 1) return cx.render(gooey.ui.box(.{}, .{}));
            if (self.remaining == 2) {
                return cx.render(gooey.ui.box(.{ .style = pad }, .{gooey.ui.box(.{}, .{})}));
            }
            cx.render(gooey.ui.box(.{ .style = pad }, .{
                gooey.ui.box(.{ .style = pad }, .{NestBoxes{ .remaining = self.remaining - 2 }}),
            }));
        }
    };

    /// A window-sized box whose click requests a dialog completing on a
    /// state type that is not the root state.
    fn dialogButton(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .key = .{ .name = "open" },
            .on_click = cx.on(requestDialog, .{}),
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
        }, .{}));
    }

    fn requestDialog(_: *CoreState, effects: *gooey.Effects) void {
        const on_complete = effects.handler(Stranger.picked);
        effects.openFileDialog(.{ .kind = .{ .open = open_many }, .on_complete = on_complete });
    }

    /// A window-sized box whose click requests a multiple selection.
    fn manyButton(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .key = .{ .name = "open" },
            .on_click = cx.on(requestMany, .{}),
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
        }, .{}));
    }

    fn requestMany(_: *CoreState, effects: *gooey.Effects) void {
        const on_complete = effects.handler(CoreState.picked);
        effects.openFileDialog(.{ .kind = .{ .open = open_many }, .on_complete = on_complete });
    }

    const open_many: gooey.PathPromptOptions = .{
        .files = true,
        .directories = false,
        .multiple = true,
    };

    const Stranger = struct {
        fn picked(_: *Stranger) void {}
    };

    fn monoText(cx: *gooey.Cx) void {
        cx.render(gooey.ui.text("code", .{ .family = .mono }));
    }

    /// One empty line per newline, then "m": one more line than the pool
    /// holds, in 1,025 bytes, which every shaper measures.
    fn wrapLines(cx: *gooey.Cx) void {
        const lines = comptime newlinesThenM(gooey.internals.layout.engine.MAX_LINES_PER_TEXT);
        cx.render(gooey.ui.text(&lines, .{ .wrap = .newlines }));
    }

    /// One empty word per newline, then "m": one more word than the pool
    /// holds. Words are scanned before lines are packed, so the word pool is
    /// the one exhausted.
    fn wrapWords(cx: *gooey.Cx) void {
        const words = comptime newlinesThenM(gooey.internals.layout.engine.MAX_WORDS_PER_TEXT);
        cx.render(gooey.ui.text(&words, .{ .wrap = .words }));
    }

    /// `nano` draws at most 1,024 glyphs, so the frame holds 1,024 wrapped
    /// lines: the first text claims 1,000 and the second asks for 25.
    fn wrapFrame(cx: *gooey.Cx) void {
        const first = comptime newlinesThenM(999);
        const second = comptime newlinesThenM(24);
        cx.render(gooey.ui.box(.{}, .{
            gooey.ui.text(&first, .{ .wrap = .newlines }),
            gooey.ui.text(&second, .{ .wrap = .newlines }),
        }));
    }

    /// One row more than the row type's `count_max`.
    fn longList(cx: *gooey.Cx) void {
        cx.render(components.List(TallRow){ .key = "rows", .count = TallRow.count_max + 1 });
    }

    const TallRow = struct {
        index: u32,

        pub const count_max: u32 = 64;

        pub fn height(_: *gooey.Cx, _: u32) f32 {
            return 10;
        }

        pub fn render(_: TallRow, _: *gooey.Cx) void {}
    };
    /// One point more than `nano` allows polylines in a frame.
    fn longPolyline(cx: *gooey.Cx) void {
        const nothing: u8 = 0;
        cx.render(gooey.ui.paint(u8, &nothing, paintLongPolyline, .{}));
    }

    fn paintLongPolyline(_: *const u8, painter: *gooey.ui.Painter) void {
        const count = gooey.ResourceLimits.nano.paint.polyline_point_count_frame_max + 1;
        const points = comptime blk: {
            @setEvalBranchQuota(4 * count);
            var result: [count][2]f32 = undefined;
            for (&result, 0..) |*point, index| point.* = .{ @floatFromInt(index), 0 };
            break :blk result;
        };
        painter.polyline(&points, 1, gooey.ui.Color.rgb(1, 1, 1));
    }

    fn manyPolylines(cx: *gooey.Cx) void {
        const nothing: u8 = 0;
        cx.render(gooey.ui.paint(u8, &nothing, paintManyPolylines, .{}));
    }

    /// Exactly `nano`'s polylines, then one more.
    fn paintManyPolylines(_: *const u8, painter: *gooey.ui.Painter) void {
        const count = gooey.ResourceLimits.nano.paint.polyline_count_frame_max + 1;
        const points = [2][2]f32{ .{ 0, 0 }, .{ 10, 10 } };
        for (0..count) |_| painter.polyline(&points, 1, gooey.ui.Color.rgb(1, 1, 1));
    }

    /// One distinct image path more than `nano`'s request entries, in one
    /// frame; the files do not exist, so none is decoded before the panic.
    fn manyImages(cx: *gooey.Cx) void {
        const nothing: u8 = 0;
        cx.render(gooey.ui.paint(u8, &nothing, paintManyImages, .{
            .width = .{ .fixed = 10 },
            .height = .{ .fixed = 10 },
        }));
    }

    fn paintManyImages(_: *const u8, painter: *gooey.ui.Painter) void {
        const count = gooey.ResourceLimits.nano.atlas.image_request_count_max + 1;
        inline for (0..count) |index| {
            const path = std.fmt.comptimePrint("assets/missing-{d}.png", .{index});
            painter.image(path, painter.bounds, .{ .fit = .contain });
        }
    }

    fn newlinesThenM(comptime count: u32) [count + 1]u8 {
        var bytes: [count + 1]u8 = undefined;
        @memset(bytes[0..count], '\n');
        bytes[count] = 'm';
        return bytes;
    }
};

fn initCoreApp(comptime App: type, gpa: std.mem.Allocator, io: std.Io) *App {
    const app = gpa.create(App) catch |err| {
        std.debug.panic("setup: core app allocation failed: {s}", .{@errorName(err)});
    };
    app.initHeadless(gpa, io, .{ .scale_factor = 1 }) catch |err| {
        std.debug.panic("setup: core app init failed: {s}", .{@errorName(err)});
    };
    return app;
}

fn coreAllocation(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(gooey.App(CoreState, CoreApp.empty, core_config), gpa, io);
    const bytes = app.guard.allocator().alloc(u8, 16) catch return;
    _ = bytes;
}

fn coreDialogTarget(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(gooey.App(CoreState, CoreApp.dialogButton, core_config), gpa, io);
    clickCenter(app);
}

fn coreDialogPaths(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(gooey.App(CoreState, CoreApp.manyButton, core_config), gpa, io);
    var context: u8 = 0;
    app.window.file_dialog = .{ .context = &context, .open = TooManyPaths.open };
    clickCenter(app);
}

/// A dialog service that selects one path more than `nano` allows.
const TooManyPaths = struct {
    const count = gooey.ResourceLimits.nano.events.dialog_path_count_max + 1;
    const bytes: []const u8 = &joined: {
        var paths: [3 * count - 1]u8 = undefined;
        for (0..count) |index| {
            paths[3 * index] = '/';
            paths[3 * index + 1] = 'a';
            if (index + 1 < count) paths[3 * index + 2] = 0;
        }
        const result = paths;
        break :joined result;
    };

    fn open(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: u32,
        _: gooey.internals.handler.FileDialogRequest,
    ) ?gooey.internals.events.Completion.Outcome {
        return .{ .file_selected = .{ .bytes = bytes, .count = count } };
    }
};

/// Tick once, then click the window's centre and tick again.
fn clickCenter(app: anytype) void {
    app.tick(1);
    const point = gooey.input.MouseEvent{
        .position = .{ .x = 50, .y = 50 },
        .button = .left,
        .click_count = 1,
        .modifiers = .{},
    };
    app.window.queue.push(.{ .input = .{ .mouse_down = point } });
    app.window.queue.push(.{ .input = .{ .mouse_up = point } });
    app.tick(2);
}

fn coreDeinitRunning(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(gooey.App(CoreState, CoreApp.empty, core_config), gpa, io);
    app.tick(1);
    app.deinit();
}

fn coreTick(gpa: std.mem.Allocator, io: std.Io, comptime render: fn (*gooey.Cx) void) void {
    const app = initCoreApp(gooey.App(CoreState, render, core_config), gpa, io);
    app.tick(1);
}

/// Pack one record more than the packed frame's draws or clips hold. The
/// records frame is reserved larger, the mismatch pack's check names.
fn corePackRecords(gpa: std.mem.Allocator, pool: enum { draws, clips }) void {
    const internals = gooey.internals;
    const records = internals.records;
    const record_count_max: u32 = 8;
    const frame = gpa.create(records.Frame) catch |err| {
        std.debug.panic("setup: records.Frame allocation failed: {s}", .{@errorName(err)});
    };
    frame.initInPlace(gpa, &.{
        .paint_record_count_max = 4 * record_count_max,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .text_bytes_max = 1,
        .mesh_point_count_max = 1,
    }) catch |err| {
        std.debug.panic("setup: records.Frame.initInPlace failed: {s}", .{@errorName(err)});
    };
    const target = gpa.create(internals.packed_frame.PackedFrame) catch |err| {
        std.debug.panic("setup: PackedFrame allocation failed: {s}", .{@errorName(err)});
    };
    target.initInPlace(&.{
        .paint = internals.limits.PaintLimits.nano,
        .paint_record_count_max = record_count_max,
    }) catch |err| {
        std.debug.panic("setup: PackedFrame.initInPlace failed: {s}", .{@errorName(err)});
    };
    frame.reset(1, .{ .width = 100, .height = 100, .scale_factor = 1 });
    for (0..record_count_max + 1) |index| {
        const offset: f32 = @floatFromInt(index);
        const bounds: records.Rect = .{ .x = offset, .y = 0, .width = 4, .height = 4 };
        const white: records.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
        switch (pool) {
            // Alternating pipelines: every record starts a draw.
            .draws => frame.appendPaint(if (index % 2 == 0) .{ .quad = .{
                .bounds = bounds,
                .fill = white,
                .border = .none,
                .corners = .zero,
                .blur = 0,
            } } else .{ .sprite = .{
                .bounds = bounds,
                .atlas = .glyph,
                .uv = .{ .x = 0, .y = 0, .width = 0.5, .height = 0.5 },
                .tint = white,
                .secondary = white,
                .corners = .zero,
                .grayscale = 0,
                .opacity = 1,
            } }),
            .clips => {
                frame.appendPaint(.{ .clip_push = bounds });
                frame.appendPaint(.clip_pop);
            },
        }
    }
    internals.pack.pack(frame, target);
}

/// Pack one polyline and check the frame against a renderer without meshes.
fn coreCapabilitiesMeshes(gpa: std.mem.Allocator) void {
    const internals = gooey.internals;
    const records = internals.records;
    const frame = gpa.create(records.Frame) catch |err| {
        std.debug.panic("setup: records.Frame allocation failed: {s}", .{@errorName(err)});
    };
    frame.initInPlace(gpa, &.{
        .paint_record_count_max = 4,
        .hit_record_count_max = 1,
        .handler_count_max = 1,
        .a11y_node_count_max = 1,
        .text_bytes_max = 1,
        .mesh_point_count_max = 2,
    }) catch |err| {
        std.debug.panic("setup: records.Frame.initInPlace failed: {s}", .{@errorName(err)});
    };
    const target = gpa.create(internals.packed_frame.PackedFrame) catch |err| {
        std.debug.panic("setup: PackedFrame allocation failed: {s}", .{@errorName(err)});
    };
    target.initInPlace(&.{
        .paint = internals.limits.PaintLimits.nano,
        .paint_record_count_max = 4,
    }) catch |err| {
        std.debug.panic("setup: PackedFrame.initInPlace failed: {s}", .{@errorName(err)});
    };
    frame.reset(1, .{ .width = 100, .height = 100, .scale_factor = 1 });
    const range = frame.claimMeshPoints(2);
    frame.meshPoints(range)[0] = .{ .x = 0, .y = 0 };
    frame.meshPoints(range)[1] = .{ .x = 50, .y = 50 };
    frame.mesh_point_counts[@backingInt(records.Mesh.Topology.strip_expanded)] += 2;
    frame.appendPaint(.{ .mesh = .{
        .range = range,
        .topology = .strip_expanded,
        .fill = .{ .r = 0, .g = 0, .b = 0, .a = 1 },
        .width = 2,
    } });
    internals.pack.pack(frame, target);
    internals.backend.checkCapabilities(.{ .meshes = false }, target);
}
