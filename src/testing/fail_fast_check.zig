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
//! - `glyph-cache`: renders 513 distinct glyphs in one frame, one past `nano`'s
//!   512 `text.glyph_cache_count_max`; every entry is in use, so none is evicted.
//! - `core-allocation`: allocates through the 0.4.0 core's lifecycle guard after init.
//! - `core-duplicate-key`: renders two boxes with one key under one parent.
//! - `core-component-depth`: nests components one level past `component_depth_max`.
//! - `core-box-depth`: nests boxes one level past `nano`'s `build.box_depth_max`
//!   of 64, the window root included. The layout open stack is sized from the
//!   same field, so the build's own check, which knows the frame, stops it.
//! - `core-layout-elements`: renders one box more than `nano`'s 512 elements.
//!   The layout engine holds the same budget plus the root, so the build stops
//!   it first and layout is never asked for more.
//! - `svg-cache`: caches 9 distinct icons in one frame in an SVG atlas of 8
//!   `atlas.svg_entry_count_max`; every icon is in use, so none is reclaimed.
//!   Through the core this cannot fire: the budget holds a frame's icons.
//! - `image-cache`: the same for images, 9 into 8 `atlas.image_entry_count_max`.
//! - `core-layer-count`: opens one layer more than `nano`'s 8. Each layer is a
//!   layout floating root, a pool sized from `build.layer_count_frame_max`.
//! - `core-a11y-elements`: renders one accessible box more than `nano`'s 128
//!   `a11y.element_count_max`. The frame's node pool, the tree and every
//!   bridge are sized from that field, so the frame's pool stops it first.
//! - `core-a11y-announcement-bytes`: one click announcing 129 bytes, one past
//!   `nano`'s 128 `a11y.announcement_message_bytes_max`. Pending announcements
//!   never run out of slots: a newer one replaces an older one (contract §4).
//! - `core-opacity-range`: a box whose `Style.opacity` is just above 1.
//! - `core-grow-weight`: a box that grows with a weight of 0.
//! - `core-wrap-column`: a column that asks to wrap.
//! - `core-aspect-ratio`: a box whose aspect ratio is 0.
//! - `core-aspect-height`: a box with an aspect ratio and a fixed height.
//! - `core-pointer-drag-unkeyed`: a box with `on_pointer_drag` and no key.
//! - `core-drag-unkeyed`: a box with `draggable` and no key.
//! - `core-drag-both`: a keyed box with both `draggable` and `on_pointer_drag`.
//! - `core-start-drag-target`: a click asks `effects.startDrag` for its own box,
//!   which is keyed and on screen but not draggable.
//! - `core-dialog-target`: names a non-root state as a file dialog's completion handler.
//! - `core-dialog-paths`: a dialog selects one path more than `dialog_path_count_max`.
//! - `core-dialog-count`: one file dialog more than `events.dialog_count_max` stays open.
//! - `core-job-count`: spawns one background job more than `nano`'s 2
//!   `events.job_count_max` while both slots run.
//! - `core-job-count-cancelled`: the same after cancelling the first job and
//!   letting its interrupt end it: its slot stays held until a drain
//!   delivers its `on_done`, so the third spawn still finds both in use.
//! - `core-mono-unset`: draws `.family = .mono` text in an app with no `fonts.mono`.
//! - `core-wrap-text`: one text of 1,024 newlines and a letter, 1,025 lines,
//!   one past `nano`'s frame line budget, which one text may fill alone. A
//!   text's length is otherwise unbounded: layout and emit split it into
//!   shaping runs, so `text.run_codepoint_count_max` never stops a text.
//! - `core-wrap-frame`: wraps two texts into one line past the frame's glyph budget.
//! - `core-deinit-running`: frees a running app without stopping it first.
//! - `core-list-count`: a `List` of per-row heights one row past its `count_max`.
//! - `core-mesh-points`: a polyline one point past `nano`'s polyline point limit.
//! - `core-image-requests`: one more image path than `nano`'s image request entries.
//! - `core-image-path`: an image path one byte past `nano`'s 1,024
//!   `atlas.image_path_bytes_max`.
//! - `core-pack-polylines`: one polyline more than `nano`'s polyline limit, which
//!   pack checks: emit bounds only their points.
//! - `core-pack-draws`: packs nine records that each start a draw into a packed
//!   frame reserved for eight paint records.
//! - `core-pack-clips`: packs nine clip pushes into the same frame, one past its
//!   nine clips (eight plus the unbounded clip).
//! - `core-capabilities-meshes`: checks a frame holding a polyline against a
//!   renderer that reports no mesh support.
//! - `chart-points`: fills a line chart series of 4 `point_count_max` exactly,
//!   then adds a fifth point.
//! - `chart-categories`: builds a bar chart series of 2 `category_count_max`
//!   from 3 categories.
//! - `chart-slices`: draws a pie chart of 2 `slice_count_max` from 3 slices.

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
    @"core-pointer-drag-unkeyed",
    @"core-drag-unkeyed",
    @"core-drag-both",
    @"core-start-drag-target",
    @"core-dialog-target",
    @"core-dialog-paths",
    @"core-dialog-count",
    @"core-job-count",
    @"core-job-count-cancelled",
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
        .@"core-pointer-drag-unkeyed" => coreTick(init.gpa, init.io, CoreApp.unkeyedDrag),
        .@"core-drag-unkeyed" => coreTick(init.gpa, init.io, CoreApp.unkeyedDraggable),
        .@"core-drag-both" => coreTick(init.gpa, init.io, CoreApp.dragBoth),
        .@"core-start-drag-target" => coreStartDragTarget(init.gpa, init.io),
        .@"core-dialog-target" => coreDialogTarget(init.gpa, init.io),
        .@"core-dialog-paths" => coreDialogPaths(init.gpa, init.io),
        .@"core-dialog-count" => coreDialogCount(init.gpa, init.io),
        .@"core-job-count" => coreJobCount(init.gpa, init.io),
        .@"core-job-count-cancelled" => coreJobCountCancelled(init.gpa, init.io),
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
    // The standard set loads regular, medium, semibold, bold, italic, and bold
    // italic. Light is a valid variant that the set omits, so measuring it must
    // name the variant and the loaded set instead of substituting another face.
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

/// A 64² CPU-texture atlas of `kind` over its own journal, at frame 2.
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

fn glyphCache(gpa: std.mem.Allocator, io: std.Io) void {
    // 27 letters at 19 sizes, 8 to 26 px, are 513 distinct keys: `nano`'s 512
    // `text.glyph_cache_count_max` exactly, then one more, all in one frame,
    // so no entry may be evicted. The 1,024 px atlas and 1 MiB upload budget
    // hold every glyph, so the cache is the pool that runs out.
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

/// An atlas over its own CPU journal at frame 2, for the cache checks.
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
    // Nine 16 px squares, offset so each path differs, fill 9 of a 512² atlas's
    // shelves easily: only the 8-entry map can run out.
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
        // The 9th call is the one past the budget, in a fresh frame budget.
        if (index == 8) svg_atlas.resetFrameBudget();
        var path_buffer: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "M{d} 0L24 0L24 24Z", .{index}) catch {
            unreachable; // 32 bytes hold every path above.
        };
        _ = svg_atlas.getOrRasterize(path, 24, 16, true, null) catch |err| {
            std.debug.panic("getOrRasterize failed instead of panicking: {s}", .{@errorName(err)});
        };
    }
}

fn imageCache(gpa: std.mem.Allocator, io: std.Io) void {
    // Nine 8×8 images in a 512² atlas; only the 8-entry map can run out.
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
            unreachable; // 16 bytes hold every name above.
        };
        const key = image.ImageKey.initFromPath(name, null, null, 1.0);
        _ = image_atlas.cacheRgba(key, 8, 8, &pixels) catch |err| {
            std.debug.panic("cacheRgba failed instead of panicking: {s}", .{@errorName(err)});
        };
    }
}

// =============================================================================
// 0.4.0 core
// =============================================================================

const CoreState = struct {
    fn picked(_: *CoreState) void {}
    fn dragged(_: *CoreState) void {}

    fn startDrag(_: *CoreState, id: gooey.ElementId, effects: *gooey.Effects) void {
        // The call panics on a box that is not draggable; it never returns.
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

    /// A drag names its source by id across frames, so it must be keyed.
    fn unkeyedDraggable(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .draggable = .of(u32, 1),
            .style = .{ .source = @src() },
        }, .{}));
    }

    /// A press starts one gesture, so a box cannot ask for two.
    fn dragBoth(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{
            .key = .{ .name = "both" },
            .draggable = .of(u32, 1),
            .on_pointer_drag = cx.on(CoreState.dragged, .{}),
            .style = .{ .source = @src() },
        }, .{}));
    }

    /// The smallest invalid weight; any positive weight is valid.
    fn growWeight(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .width = .{ .grow = 0 } } }, .{}));
    }

    /// A column is the default direction, so `wrap` alone asks a column.
    fn wrapColumn(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .wrap = true } }, .{}));
    }

    /// The smallest invalid ratio; any positive finite ratio is valid.
    fn aspectRatio(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{ .aspect_ratio = 0 } }, .{}));
    }

    /// A valid ratio with a height of its own, which the ratio would replace.
    fn aspectHeight(cx: *gooey.Cx) void {
        cx.render(gooey.ui.box(.{ .style = .{
            .width = .{ .fixed = 160 },
            .height = .{ .fixed = 90 },
            .aspect_ratio = 16.0 / 9.0,
        } }, .{}));
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

    /// 64 nested boxes inside the window root: one level past the budget,
    /// which counts the root.
    fn deepBoxes(cx: *gooey.Cx) void {
        const box_count = gooey.ResourceLimits.nano.build.box_depth_max;
        cx.render(NestBoxes{ .remaining = box_count });
    }

    /// Exactly `nano`'s elements as sibling boxes, then one more.
    fn manyBoxes(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.build.element_count_frame_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{}, .{}));
    }

    /// Exactly `nano`'s layers as sibling popovers, then one more.
    fn manyLayers(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.build.layer_count_frame_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{
            .layer = .{ .kind = .popover, .anchor = .{ .parent = .{} }, .clip = .escape },
        }, .{}));
    }

    /// Exactly `nano`'s accessibility nodes as sibling buttons, then one more.
    fn manyAccessible(cx: *gooey.Cx) void {
        const count = gooey.ResourceLimits.nano.a11y.element_count_max + 1;
        for (0..count) |_| cx.render(gooey.ui.box(.{
            .a11y = .{ .role = .button, .label = "Go" },
        }, .{}));
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
    /// A keyed, window-sized button that asks to drag itself; it has no
    /// `Box.draggable`.
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

    /// One line per newline, then "m": 1,025 lines, one past `nano`'s
    /// 1,024 wrapped lines a frame, all in one text.
    fn wrapText(cx: *gooey.Cx) void {
        const run = comptime newlinesThenM(gooey.text.run_codepoint_count_max);
        cx.render(gooey.ui.text(&run, .{ .wrap = .words }));
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

        pub fn height(_: *gooey.Cx, _: u32, _: f32) f32 {
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

    fn longImagePath(cx: *gooey.Cx) void {
        const nothing: u8 = 0;
        cx.render(gooey.ui.paint(u8, &nothing, paintLongImagePath, .{
            .width = .{ .fixed = 10 },
            .height = .{ .fixed = 10 },
        }));
    }

    /// One byte past `nano`'s image path budget: exactly the budget is a
    /// valid path, and the request reserves no more.
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

/// Open `nano`'s two file dialogs, which stay open as a portal's do, then
/// one more: each click requests one, and one opens per tick.
fn coreDialogCount(gpa: std.mem.Allocator, io: std.Io) void {
    const app = initCoreApp(gooey.App(CoreState, CoreApp.manyButton, core_config), gpa, io);
    var context: u8 = 0;
    app.window.file_dialog = .{ .context = &context, .open = StaysOpen.open };
    const dialog_count_max = gooey.ResourceLimits.nano.events.dialog_count_max;
    app.tick(1);
    var opened: u32 = 0;
    while (opened <= dialog_count_max) : (opened += 1) {
        std.debug.assert(app.window.dialogs_opened == opened);
        const point = gooey.input.MouseEvent{
            .position = .{ .x = 50, .y = 50 },
            .button = .left,
            .click_count = 1,
            .modifiers = .{},
        };
        app.window.queue.push(.{ .input = .{ .mouse_down = point } });
        app.window.queue.push(.{ .input = .{ .mouse_up = point } });
        app.tick(2 + opened);
    }
    unreachable;
}

/// A job that sleeps until the app stops.
const Nap = struct {
    pub const Input = struct { seconds: u32 };
    pub const Result = struct { never: u8 };

    pub fn run(input: *const Input, job: *gooey.Job(Result)) !void {
        try job.io().sleep(.fromSeconds(input.seconds), .awake);
    }
};

fn coreJobCount(gpa: std.mem.Allocator, io: std.Io) void {
    const config = comptime blk: {
        var with_jobs = core_config;
        with_jobs.jobs = &.{Nap};
        break :blk with_jobs;
    };
    const app = initCoreApp(gooey.App(CoreState, CoreApp.empty, config), gpa, io);
    var effects = gooey.Effects.init(null, .root);
    effects.jobs = &app.window.jobs;
    const job_count_max = gooey.ResourceLimits.nano.events.job_count_max;
    var spawned: u32 = 0;
    // Exactly the capacity, then one more.
    while (spawned <= job_count_max) : (spawned += 1) {
        _ = effects.spawn(Nap, &.{ .seconds = 60 }, .{
            .on_done = effects.handler(CoreState.picked),
        });
    }
    unreachable;
}

fn coreJobCountCancelled(gpa: std.mem.Allocator, io: std.Io) void {
    const config = comptime blk: {
        var with_jobs = core_config;
        with_jobs.jobs = &.{Nap};
        break :blk with_jobs;
    };
    const app = initCoreApp(gooey.App(CoreState, CoreApp.empty, config), gpa, io);
    var effects = gooey.Effects.init(null, .root);
    effects.jobs = &app.window.jobs;
    const job_count_max = gooey.ResourceLimits.nano.events.job_count_max;
    var first: ?gooey.JobId = null;
    var spawned: u32 = 0;
    // Exactly the capacity, then cancel the first and let its interrupt
    // finish, then one more spawn with no drain in between.
    while (spawned <= job_count_max) : (spawned += 1) {
        if (spawned == job_count_max) {
            effects.cancelJob(first.?);
            io.sleep(.fromMilliseconds(100), .awake) catch |err| {
                std.debug.panic("fail_fast_check: sleep failed: {t}", .{err});
            };
        }
        const id = effects.spawn(Nap, &.{ .seconds = 60 }, .{
            .on_done = effects.handler(CoreState.picked),
        });
        if (first == null) first = id;
    }
    unreachable;
}

/// A dialog service whose dialogs never close.
const StaysOpen = struct {
    fn open(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: u32,
        _: gooey.internals.handler.FileDialogRequest,
    ) ?gooey.internals.events.Completion.Outcome {
        return null;
    }
};

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

/// Click a button announcing one byte more than `nano`'s announcement slot.
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
    // Four points fill the series exactly; the fifth names the field to raise.
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
    // Three categories built into a series of two.
    const Chart = charts.BarChart(.{ .category_count_max = 2, .series_count_max = 1 });
    _ = Chart.Series.fromSlice("sales", &.{
        .{ .label = "A", .value = 1 },
        .{ .label = "B", .value = 2 },
        .{ .label = "C", .value = 3 },
    }, null);
}

fn chartSlices() void {
    // Three slices drawn by a pie of two.
    const Chart = charts.PieChart(.{ .slice_count_max = 2 });
    const slices = [_]charts.CategoryPoint{
        charts.CategoryPoint.init("A", 1),
        charts.CategoryPoint.init("B", 2),
        charts.CategoryPoint.init("C", 3),
    };
    comptime std.debug.assert(slices.len == Chart.slice_count_max + 1);
    _ = Chart.init(&slices);
}
