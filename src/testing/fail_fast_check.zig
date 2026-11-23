const std = @import("std");
const gooey = @import("gooey");
const components = @import("gooey-components");
const charts = @import("gooey-charts");

const Mode = enum {
    @"font-variant",
    @"atlas-item",
    @"atlas-live-set",
    @"glyph-cache",
    @"svg-cache",
    @"image-cache",
    @"core-allocation",
    @"core-duplicate-key",
    @"core-component-depth",
    @"core-box-depth",
    @"core-layout-elements",
    @"core-layer-count",
    @"core-a11y-elements",
    @"core-a11y-announcement-bytes",
    @"core-opacity-range",
    @"core-grow-weight",
    @"core-wrap-column",
    @"core-aspect-ratio",
    @"core-aspect-height",
    @"core-grid-columns",
    @"core-grid-rows",
    @"core-grid-track",
    @"core-grid-wrap",
    @"core-grid-alignment",
    @"core-grid-span",
    @"core-grid-column",
    @"core-grid-cell-outside",
    @"core-grid-row-box",
    @"core-grid-row-box-cells",
    @"core-grid-count",
    @"core-text-line-count-zero",
    @"core-text-line-count-none",
    @"core-pointer-drag-unkeyed",
    @"core-drag-unkeyed",
    @"core-drag-both",
    @"core-start-drag-target",
    @"core-dialog-target",
    @"core-dialog-paths",
    @"core-job-posts",
    @"core-mono-unset",
    @"core-wrap-text",
    @"core-wrap-frame",
    @"core-deinit-running",
    @"core-list-count",
    @"core-mesh-points",
    @"core-image-requests",
    @"core-image-path",
    @"core-pack-polylines",
    @"core-pack-draws",
    @"core-pack-clips",
    @"core-capabilities-meshes",
    @"chart-points",
    @"chart-categories",
    @"chart-slices",
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
        .@"glyph-cache" => glyphCache(init.gpa, init.io),
        .@"svg-cache" => svgCache(init.gpa, init.io),
        .@"image-cache" => imageCache(init.gpa, init.io),
        .@"core-allocation" => coreAllocation(init.gpa, init.io),
        .@"core-duplicate-key" => coreTick(init.gpa, init.io, CoreApp.duplicateKey),
        .@"core-component-depth" => coreTick(init.gpa, init.io, CoreApp.nested),
        .@"core-box-depth" => coreTick(init.gpa, init.io, CoreApp.deepBoxes),
        .@"core-layout-elements" => coreTick(init.gpa, init.io, CoreApp.manyBoxes),
        .@"core-layer-count" => coreTick(init.gpa, init.io, CoreApp.manyLayers),
        .@"core-a11y-elements" => coreTick(init.gpa, init.io, CoreApp.manyAccessible),
        .@"core-a11y-announcement-bytes" => coreAnnounce(init.gpa, init.io),
        .@"core-opacity-range" => coreTick(init.gpa, init.io, CoreApp.opacityRange),
        .@"core-grow-weight" => coreTick(init.gpa, init.io, CoreApp.growWeight),
        .@"core-wrap-column" => coreTick(init.gpa, init.io, CoreApp.wrapColumn),
        .@"core-aspect-ratio" => coreTick(init.gpa, init.io, CoreApp.aspectRatio),
        .@"core-aspect-height" => coreTick(init.gpa, init.io, CoreApp.aspectHeight),
        .@"core-grid-columns" => coreTick(init.gpa, init.io, CoreApp.gridColumns),
        .@"core-grid-rows" => coreTick(init.gpa, init.io, CoreApp.gridRows),
        .@"core-grid-track" => coreTick(init.gpa, init.io, CoreApp.gridTrack),
        .@"core-grid-wrap" => coreTick(init.gpa, init.io, CoreApp.gridWrap),
        .@"core-grid-alignment" => coreTick(init.gpa, init.io, CoreApp.gridAlignment),
        .@"core-grid-span" => coreTick(init.gpa, init.io, CoreApp.gridSpan),
        .@"core-grid-column" => coreTick(init.gpa, init.io, CoreApp.gridColumn),
        .@"core-grid-cell-outside" => coreTick(init.gpa, init.io, CoreApp.gridCellOutside),
        .@"core-grid-row-box" => coreTick(init.gpa, init.io, CoreApp.gridRowBox),
        .@"core-grid-row-box-cells" => coreTick(init.gpa, init.io, CoreApp.gridRowBoxCells),
        .@"core-grid-count" => coreTick(init.gpa, init.io, CoreApp.manyGrids),
        .@"core-text-line-count-zero" => coreTick(init.gpa, init.io, CoreApp.textLineCountZero),
        .@"core-text-line-count-none" => coreTick(init.gpa, init.io, CoreApp.textLineCountNone),
        .@"core-pointer-drag-unkeyed" => coreTick(init.gpa, init.io, CoreApp.unkeyedDrag),
        .@"core-drag-unkeyed" => coreTick(init.gpa, init.io, CoreApp.unkeyedDraggable),
        .@"core-drag-both" => coreTick(init.gpa, init.io, CoreApp.dragBoth),
        .@"core-start-drag-target" => coreStartDragTarget(init.gpa, init.io),
        .@"core-dialog-target" => coreDialogTarget(init.gpa, init.io),
        .@"core-dialog-paths" => coreDialogPaths(init.gpa, init.io),
        .@"core-job-posts" => coreJobPosts(init.gpa, init.io),
        .@"core-mono-unset" => coreTick(init.gpa, init.io, CoreApp.monoText),
        .@"core-wrap-text" => coreTick(init.gpa, init.io, CoreApp.wrapText),
        .@"core-wrap-frame" => coreTick(init.gpa, init.io, CoreApp.wrapFrame),
        .@"core-deinit-running" => coreDeinitRunning(init.gpa, init.io),
        .@"core-list-count" => coreTick(init.gpa, init.io, CoreApp.longList),
        .@"core-mesh-points" => coreTick(init.gpa, init.io, CoreApp.longPolyline),
        .@"core-image-requests" => coreTick(init.gpa, init.io, CoreApp.manyImages),
        .@"core-image-path" => coreTick(init.gpa, init.io, CoreApp.longImagePath),
        .@"core-pack-polylines" => coreTick(init.gpa, init.io, CoreApp.manyPolylines),
        .@"core-pack-draws" => corePackRecords(init.gpa, .draws),
        .@"core-pack-clips" => corePackRecords(init.gpa, .clips),
        .@"core-capabilities-meshes" => coreCapabilitiesMeshes(init.gpa),
        .@"chart-points" => chartPoints(),
        .@"chart-categories" => chartCategories(),
        .@"chart-slices" => chartSlices(),
    }
    std.debug.print("unreachable: {s} did not panic\n", .{@tagName(mode)});
}

fn fontVariant(gpa: std.mem.Allocator, io: std.Io) void {
    const text = gooey.internals.text;
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
    const text_limits = &gooey.ResourceLimits.standard.text;
    text_system.initInPlace(gpa, 1.0, io, text_limits, atlas_options) catch |err| {
        std.debug.panic("setup: TextSystem.initInPlace failed: {s}", .{@errorName(err)});
    };
    text_system.loadSystemFont(.sans_serif, 16) catch |err| {
        std.debug.panic("setup: loadSystemFont failed: {s}", .{@errorName(err)});
    };
    _ = text_system.measureText(.app, "Total", .light) catch |err| {
        std.debug.panic("measureText failed instead of panicking: {s}", .{@errorName(err)});
    };
}

fn atlasHarness(gpa: std.mem.Allocator, io: std.Io, kind: gooey.internals.text.AtlasKind) *gooey.internals.text.Atlas {
    const text = gooey.internals.text;
    const uploads = gpa.create(text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    const upload_options: text.AtlasUploads.Options = .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 64,
        .consumer_count_max = 1,
    };
    uploads.init(gpa, io, upload_options) catch |err| {
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
    const atlas = atlasHarness(gpa, io, .text);
    var pixels: [63 * 4]u8 = @splat(1);
    _ = atlas.insert(63, 4, &pixels);
}

fn atlasLiveSet(gpa: std.mem.Allocator, io: std.Io) void {
    const atlas = atlasHarness(gpa, io, .svg);
    var pixels: [62 * 14 * 4]u8 = @splat(1);
    var index: u32 = 0;
    while (index < 4) : (index += 1) {
        std.debug.assert(atlas.insert(62, 14, &pixels) != null);
    }
    std.debug.assert(atlas.rows_active == 64);
    _ = atlas.insert(62, 14, &pixels);
}

fn glyphCache(gpa: std.mem.Allocator, io: std.Io) void {
    const text = gooey.internals.text;
    const glyph_count_max = gooey.ResourceLimits.nano.text.glyph_cache_count_max;
    const letters = "abcdefghijklmnopqrstuvwxyzA";
    const size_min: u32 = 8;
    const size_count: u32 = 19;
    comptime std.debug.assert(letters.len * size_count == glyph_count_max + 1);

    const uploads = gpa.create(text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    const upload_options: text.AtlasUploads.Options = .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 1024 * 1024,
        .consumer_count_max = 1,
    };
    uploads.init(gpa, io, upload_options) catch |err| {
        std.debug.panic("setup: AtlasUploads.init failed: {s}", .{@errorName(err)});
    };
    const text_system = gpa.create(text.TextSystem) catch |err| {
        std.debug.panic("setup: TextSystem allocation failed: {s}", .{@errorName(err)});
    };
    const atlas_options: text.AtlasOptions = .{ .size = 1024, .uploads = uploads };
    const text_limits = &gooey.ResourceLimits.nano.text;
    text_system.initInPlace(gpa, 1.0, io, text_limits, atlas_options) catch |err| {
        std.debug.panic("setup: TextSystem.initInPlace failed: {s}", .{@errorName(err)});
    };
    text_system.loadSystemFont(.sans_serif, 16) catch |err| {
        std.debug.panic("setup: loadSystemFont failed: {s}", .{@errorName(err)});
    };
    const run = text_system.shapeText(.app, letters, .regular, null) catch |err| {
        std.debug.panic("setup: shapeText failed: {s}", .{@errorName(err)});
    };
    std.debug.assert(run.glyphs.len == letters.len);
    _ = uploads.beginFrame(1);
    var size_index: u32 = 0;
    while (size_index < size_count) : (size_index += 1) {
        if (size_index + 1 == size_count) {
            std.debug.assert(text_system.cache.entry_count == glyph_count_max + 1 - letters.len);
        }
        const size: f32 = @floatFromInt(size_min + size_index);
        for (run.glyphs) |glyph| {
            _ = text_system.getGlyphSubpixel(glyph.glyph_id, size, 0, 0) catch |err| {
                std.debug.panic("getGlyphSubpixel failed instead of panicking: {s}", .{
                    @errorName(err),
                });
            };
        }
    }
}

fn cacheUploads(gpa: std.mem.Allocator, io: std.Io) *gooey.internals.text.AtlasUploads {
    const uploads = gpa.create(gooey.internals.text.AtlasUploads) catch |err| {
        std.debug.panic("setup: AtlasUploads allocation failed: {s}", .{@errorName(err)});
    };
    const options: gooey.internals.text.AtlasUploads.Options = .{
        .storage = .cpu_texture,
        .upload_bytes_frame_max = 1024 * 1024,
        .consumer_count_max = 1,
    };
    uploads.init(gpa, io, options) catch |err| {
        std.debug.panic("setup: AtlasUploads.init failed: {s}", .{@errorName(err)});
    };
    const frame = uploads.beginFrame(1);
    std.debug.assert(frame == 2);
    return uploads;
}

fn svgCache(gpa: std.mem.Allocator, io: std.Io) void {
    const svg = gooey.internals.svg;
    const svg_atlas = gpa.create(svg.SvgAtlas) catch |err| {
        std.debug.panic("setup: SvgAtlas allocation failed: {s}", .{@errorName(err)});
    };
    const nano = gooey.ResourceLimits.nano.atlas;
    svg_atlas.initInPlace(gpa, 1.0, io, .{
        .size = 512,
        .icon_size_max = nano.svg_icon_size_max,
        .raster_budget = .{
            .path_bytes_max = nano.svg_path_bytes_max,
            .vertex_count_max = nano.svg_path_vertex_count_max,
        },
        .entry_count_max = 8,
        .rasterization_count_frame_max = 8,
        .uploads = cacheUploads(gpa, io),
    }) catch |err| {
        std.debug.panic("setup: SvgAtlas.initInPlace failed: {s}", .{@errorName(err)});
    };
    var index: u32 = 0;
    while (index < 9) : (index += 1) {
        if (index == 8) svg_atlas.resetFrameBudget();
        var path_buffer: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "M{d} 0L24 0L24 24Z", .{index}) catch {
            unreachable;
        };
        _ = svg_atlas.getOrRasterize(path, 24, 16, true, null) catch |err| {
            std.debug.panic("getOrRasterize failed instead of panicking: {s}", .{@errorName(err)});
        };
    }
}

fn imageCache(gpa: std.mem.Allocator, io: std.Io) void {
    const image = gooey.internals.image;
    const image_atlas = gpa.create(image.ImageAtlas) catch |err| {
        std.debug.panic("setup: ImageAtlas allocation failed: {s}", .{@errorName(err)});
    };
    image_atlas.initInPlace(gpa, 1.0, io, .{
        .size = 512,
        .entry_count_max = 8,
        .uploads = cacheUploads(gpa, io),
    }) catch |err| {
        std.debug.panic("setup: ImageAtlas.initInPlace failed: {s}", .{@errorName(err)});
    };
    var pixels: [8 * 8 * 4]u8 = @splat(255);
    var index: u32 = 0;
    while (index < 9) : (index += 1) {
        var name_buffer: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, "image-{d}", .{index}) catch {
            unreachable;
        };
        const key = image.ImageKey.initFromPath(name, null, null, 1.0);
        _ = image_atlas.cacheRgba(key, 8, 8, &pixels) catch |err| {
            std.debug.panic("cacheRgba failed instead of panicking: {s}", .{@errorName(err)});
        };
    }
}

const CoreState = struct {
    fn picked(_: *CoreState) void {}
    fn dragged(_: *CoreState) void {}

    fn startDrag(_: *CoreState, id: gooey.ElementId, effects: *gooey.Effects) void {
        _ = effects.startDrag(id);
    }
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

    fn opacityRange(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .opacity = 1.01 } }, .{}));
    }

    fn unkeyedDrag(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .on_pointer_drag = cx.on(CoreState.dragged, .{}),
            .style = .{ .source = @src() },
        }, .{}));
    }

    fn unkeyedDraggable(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .draggable = .of(u32, 1),
            .style = .{ .source = @src() },
        }, .{}));
    }

    fn dragBoth(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .key = .{ .name = "both" },
            .draggable = .of(u32, 1),
            .on_pointer_drag = cx.on(CoreState.dragged, .{}),
            .style = .{ .source = @src() },
        }, .{}));
    }

    fn growWeight(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .width = .{ .grow = 0 } } }, .{}));
    }

    fn wrapColumn(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .wrap = true } }, .{}));
    }

    fn aspectRatio(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .aspect_ratio = 0 } }, .{}));
    }

    fn aspectHeight(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{
            .width = .{ .fixed = 160 },
            .height = .{ .fixed = 90 },
            .aspect_ratio = 16.0 / 9.0,
        } }, .{}));
    }

    const two_columns = [_]gooey.ui.Track{ .fit, .fit };

    fn gridColumns(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{ .columns = &.{} } } }, .{}));
    }

    fn textLineCountZero(cx: *gooey.Cx) void {
        cx.render(gooey.ui.text("Quarterly report", .{ .wrap = .words, .line_count_max = 0 }));
    }

    fn textLineCountNone(cx: *gooey.Cx) void {
        cx.render(gooey.ui.text("Quarterly report", .{ .line_count_max = 2 }));
    }

    fn gridRows(cx: *gooey.Cx) void {
        const rows: [gooey.ui.Grid.track_count_max + 1]gooey.ui.Track = @splat(.fit);
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{
            .columns = &two_columns,
            .rows = &rows,
        } } }, .{}));
    }

    fn gridTrack(cx: *gooey.Cx) void {
        const columns = [_]gooey.ui.Track{.{ .min = 10, .max = 5 }};
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{ .columns = &columns } } }, .{}));
    }

    fn gridWrap(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{
            .direction = .row,
            .wrap = true,
            .grid = .{ .columns = &two_columns },
        } }, .{}));
    }

    fn gridAlignment(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{
            .alignment = .{ .main = .space_between },
            .grid = .{ .columns = &two_columns },
        } }, .{}));
    }

    fn gridSpan(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{ .columns = &two_columns } } }, .{
            gooey.ui.box(.{ .style = .{ .cell = .{ .column_span = 0 } } }, .{}),
        }));
    }

    fn gridColumn(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{ .columns = &two_columns } } }, .{
            gooey.ui.box(.{ .style = .{ .cell = .{ .column = 1, .column_span = 2 } } }, .{}),
        }));
    }

    fn gridCellOutside(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .cell = .{ .column = 0 } } }, .{}));
    }

    fn gridRowBox(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{ .columns = &two_columns } } }, .{
            gooey.ui.box(.{ .style = .{ .cell = .{ .row = true }, .padding = .all(4) } }, .{}),
        }));
    }

    fn gridRowBoxCells(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .grid = .{ .columns = &two_columns } } }, .{
            gooey.ui.box(.{ .style = .{ .cell = .{ .row = true } } }, .{
                gooey.ui.text("a", .{}),
                gooey.ui.text("b", .{}),
                gooey.ui.text("c", .{}),
            }),
        }));
    }

    fn manyGrids(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.build.grid_count_frame_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{
            .style = .{ .grid = .{ .columns = &two_columns } },
        }, .{}));
    }

    const Nest = struct {
        pub fn render(self: Nest, cx: *gooey.Cx) void {
            cx.render(self);
        }
    };

    fn nested(cx: *gooey.Cx) void {
        cx.render(Nest{});
    }

    fn deepBoxes(cx: *gooey.Cx) void {
        const box_count = gooey.ResourceLimits.nano.build.box_depth_max;
        cx.render(NestBoxes{ .remaining = box_count });
    }

    fn manyBoxes(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.build.element_count_frame_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{}, .{}));
    }

    fn manyLayers(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.build.layer_count_frame_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{
            .layer = .{ .kind = .popover, .anchor = .{ .parent = .{} }, .clip = .escape },
        }, .{}));
    }

    fn manyAccessible(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.a11y.element_count_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{
            .a11y = .{ .role = .button, .label = "Go" },
        }, .{}));
    }

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

    fn startDragButton(cx: *gooey.Cx) void {
        const key: gooey.Key = .{ .name = "drag" };
        cx.render(gooey.ui.box(.{
            .key = key,
            .on_click = cx.on(CoreState.startDrag, .{ .arg = cx.id(key) }),
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
        }, .{}));
    }

    fn dialogButton(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .key = .{ .name = "open" },
            .on_click = cx.on(requestDialog, .{}),
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
        }, .{}));
    }

    fn requestDialog(_: *CoreState, effects: *gooey.Effects) void {
        const on_complete = effects.handler(Stranger.picked);
        effects.openFileDialog(.{
            .kind = .{ .open = open_many },
            .on_complete = on_complete,
        }) catch |err| switch (err) {
            error.DialogBusy => unreachable,
        };
    }

    fn manyButton(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .key = .{ .name = "open" },
            .on_click = cx.on(requestMany, .{}),
            .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
        }, .{}));
    }

    fn requestMany(_: *CoreState, effects: *gooey.Effects) void {
        const on_complete = effects.handler(CoreState.picked);
        effects.openFileDialog(.{
            .kind = .{ .open = open_many },
            .on_complete = on_complete,
        }) catch |err| switch (err) {
            error.DialogBusy => unreachable,
        };
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

    fn wrapText(cx: *gooey.Cx) void {
        const run = comptime newlinesThenM(gooey.text.run_codepoint_count_max);
        cx.render(gooey.ui.text(&run, .{ .wrap = .words }));
    }

    fn wrapFrame(cx: *gooey.Cx) void {
        const first = comptime newlinesThenM(999);
        const second = comptime newlinesThenM(24);
        cx.render(gooey.ui.box(.{}, .{
            gooey.ui.text(&first, .{ .wrap = .newlines }),
            gooey.ui.text(&second, .{ .wrap = .newlines }),
        }));
    }

    fn longList(cx: *gooey.Cx) void {
        cx.render(components.List(TallRow){ .key = "rows", .count = TallRow.count_max + 1 });
    }

    const TallRow = struct {
        index: u32,

        pub const count_max: u32 = 64;

        pub fn height(_: *gooey.Cx, _: u32, _: f32) f32 {
            return 10;
        }

        pub fn render(_: TallRow, _: *gooey.Cx) void {}
    };
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

    fn paintManyPolylines(_: *const u8, painter: *gooey.ui.Painter) void {
        const count = gooey.ResourceLimits.nano.paint.polyline_count_frame_max + 1;
        const points = [2][2]f32{ .{ 0, 0 }, .{ 10, 10 } };
        for (0..count) |_| painter.polyline(&points, 1, gooey.ui.Color.rgb(1, 1, 1));
    }

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

    fn longImagePath(cx: *gooey.Cx) void {
        const nothing: u8 = 0;
        cx.render(gooey.ui.paint(u8, &nothing, paintLongImagePath, .{
            .width = .{ .fixed = 10 },
            .height = .{ .fixed = 10 },
        }));
    }

    fn paintLongImagePath(_: *const u8, painter: *gooey.ui.Painter) void {
        const path_bytes = gooey.ResourceLimits.nano.atlas.image_path_bytes_max + 1;
        const path: [path_bytes]u8 = @splat('a');
        painter.image(&path, painter.bounds, .{ .fit = .contain });
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

fn coreStartDragTarget(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(gooey.App(CoreState, CoreApp.startDragButton, core_config), gpa, io);
    clickCenter(app);
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

const Overpost = struct {
    pub const Input = struct { unused: u8 };
    pub const Result = struct { value: u32 };
    pub const posts_max: u32 = 1;

    pub fn run(_: *const Input, job: *gooey.Job(Result)) void {
        if (!job.post(&.{ .value = 1 })) unreachable;
        if (!job.post(&.{ .value = 2 })) unreachable;
    }
};

fn coreJobPosts(gpa: std.mem.Allocator, io: std.Io) void {
    const config = comptime blk: {
        var with_jobs = core_config;
        with_jobs.jobs = &.{Overpost};
        break :blk with_jobs;
    };
    const App = gooey.App(CoreState, CoreApp.empty, config);
    const app = gpa.create(App) catch |err| {
        std.debug.panic("setup: core app allocation failed: {s}", .{@errorName(err)});
    };
    app.initHeadless(gpa, io, .{ .scale_factor = 1, .job_runs = .main_thread }) catch |err| {
        std.debug.panic("setup: core app init failed: {s}", .{@errorName(err)});
    };
    var effects = gooey.Effects.init(null, .root);
    effects.jobs = &app.window.jobs;
    _ = effects.spawn(Overpost, &.{ .unused = 0 }, .{
        .on_done = effects.handler(CoreState.picked),
    }) catch |err| std.debug.panic("setup: spawn refused: {t}", .{err});
    app.tick(1);
}

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

fn coreAnnounce(gpa: std.mem.Allocator, io: std.Io) void {
    const a11y = gooey.ResourceLimits.nano.a11y;
    const Announcer = struct {
        const message: [a11y.announcement_message_bytes_max + 1]u8 = @splat('a');

        fn render(cx: *gooey.Cx) void {
            cx.render(gooey.ui.box(.{
                .key = .{ .name = "announce" },
                .on_click = cx.on(say, .{}),
                .style = .{ .width = .{ .grow = 1 }, .height = .{ .grow = 1 } },
            }, .{}));
        }

        fn say(_: *CoreState, effects: *gooey.Effects) void {
            effects.announce(&message, .polite);
        }
    };
    const app = initCoreApp(gooey.App(CoreState, Announcer.render, core_config), gpa, io);
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
        .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 1 },
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
        .announcements = .{ .polite_pending_max = 1, .message_bytes_max = 1 },
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

fn chartPoints() void {
    const Chart = charts.LineChart(.{ .point_count_max = 4, .series_count_max = 1 });
    var series = Chart.Series.init("rev", null);
    var index: u32 = 0;
    while (index < Chart.point_count_max) : (index += 1) {
        series.addPoint(charts.DataPoint.init(@floatFromInt(index), 1));
    }
    std.debug.assert(series.data_len == Chart.point_count_max);
    series.addPoint(charts.DataPoint.init(4, 1));
}

fn chartCategories() void {
    const Chart = charts.BarChart(.{ .category_count_max = 2, .series_count_max = 1 });
    _ = Chart.Series.fromSlice("sales", &.{
        .{ .label = "A", .value = 1 },
        .{ .label = "B", .value = 2 },
        .{ .label = "C", .value = 3 },
    }, null);
}

fn chartSlices() void {
    const Chart = charts.PieChart(.{ .slice_count_max = 2 });
    const slices = [_]charts.CategoryPoint{
        charts.CategoryPoint.init("A", 1),
        charts.CategoryPoint.init("B", 2),
        charts.CategoryPoint.init("C", 3),
    };
    comptime std.debug.assert(slices.len == Chart.slice_count_max + 1);
    _ = Chart.init(&slices);
}
