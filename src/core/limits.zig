//! Static allocation limits for Gooey
//!
//! All buffers and pools have fixed upper bounds to eliminate allocation
//! during rendering. If you hit a limit, increase it here and rebuild.

const std = @import("std");
const assert = std.debug.assert;

// The packed frame, imported only for its pool sizes in budget and memory
// estimates. It imports this file for its limits; the cycle is between files,
// not between comptime values, so Zig resolves it.
const packed_frame = @import("packed_frame.zig");
const FontVariant = @import("../text/types.zig").FontVariant;
const ShapedGlyph = @import("../text/types.zig").ShapedGlyph;

// These are the ceilings an application budget (`ResourceLimits`) may not
// exceed. They are not the capacities a window allocates: `ResourceLimits`
// selects those, and `PaintLimits.check` enforces `budget <= ceiling`.

/// Maximum quads per frame (rectangles, backgrounds)
pub const MAX_QUADS_PER_FRAME: u32 = 65536;

/// Maximum glyphs per frame (text characters)
pub const MAX_GLYPHS_PER_FRAME: u32 = 65536;

/// Maximum shadows per frame
pub const MAX_SHADOWS_PER_FRAME: u32 = 4096;

/// Maximum SVG instances per frame
pub const MAX_SVGS_PER_FRAME: u32 = 8192;

/// Maximum images per frame
pub const MAX_IMAGES_PER_FRAME: u32 = 4096;

/// Maximum path instances per frame
pub const MAX_PATHS_PER_FRAME: u32 = 4096;

/// Maximum polylines per frame
pub const MAX_POLYLINES_PER_FRAME: u32 = 4096;

/// Maximum point clouds per frame
pub const MAX_POINT_CLOUDS_PER_FRAME: u32 = 4096;

/// Maximum clip stack depth (nested clips)
pub const MAX_CLIP_STACK_DEPTH: u32 = 32;

/// Widest framebuffer, in physical pixels, any window budget may declare (8K UHD).
pub const MAX_FRAMEBUFFER_WIDTH: u32 = 7680;

/// Tallest framebuffer, in physical pixels, any window budget may declare (8K UHD).
pub const MAX_FRAMEBUFFER_HEIGHT: u32 = 4320;

/// Most frames a renderer may have in flight. Every per-frame GPU ring, pool and
/// command buffer is reserved once per frame in flight, so this bounds them all.
pub const MAX_FRAMES_IN_FLIGHT: u32 = 3;

/// Fewest frames in flight: one the GPU reads while the CPU records the next.
pub const MIN_FRAMES_IN_FLIGHT: u32 = 2;

/// Largest atlas side, in pixels, any atlas budget may declare. 4096² RGBA is 64 MiB.
pub const MAX_ATLAS_SIZE: u32 = 4096;

/// Smallest atlas side. Atlas sides are multiples of the shelf height quantum.
pub const MIN_ATLAS_SIZE: u32 = 64;

/// Largest SVG icon side, in device pixels, any atlas budget may rasterize.
pub const MAX_SVG_ICON_SIZE: u32 = 256;

/// Most bytes of path data (raw `d` data or shape elements) any atlas budget
/// lets one SVG icon carry. Lucide's longest icon is 808 B.
pub const MAX_SVG_PATH_BYTES: u32 = 64 * 1024;

/// Most vertices one SVG icon may flatten to under any atlas budget. Curves
/// flatten to half a device pixel, so the count grows with the icon's side:
/// Lucide's heaviest, `loader_pinwheel`, is 2,140 at 64 px and 8,530 at 256.
pub const MAX_SVG_PATH_VERTEX_COUNT: u32 = 32 * 1024;

/// Largest glyph bitmap side, in device pixels (the glyph render buffer).
pub const MAX_GLYPH_SIZE: u32 = 256;

/// Most rasterized atlas bytes any budget may upload in one frame: one 4096² R8
/// atlas plus two 4096² RGBA atlases spread over three frames.
pub const MAX_ATLAS_UPLOAD_BYTES_PER_FRAME: u32 = 48 * 1024 * 1024;

/// Most images any atlas budget may have waiting for the decode worker or
/// remembered as failed at once (`AtlasLimits.image_request_count_max`).
pub const MAX_IMAGE_REQUESTS: u32 = 256;

/// Most bytes of decode staging any atlas budget may reserve: a 4096² RGBA
/// image (64 MiB) plus its compressed file and the decoder's row table.
pub const MAX_IMAGE_DECODE_BYTES: u32 = 96 * 1024 * 1024;

/// Most SVG cache entries any atlas budget may hold (`svg_entry_count_max`).
pub const MAX_SVG_ENTRIES: u32 = 16_384;

/// Most SVG icons any atlas budget may rasterize in one frame. Each costs 0.5
/// to 2 ms of software rasterization, so this is a work bound, not storage.
pub const MAX_SVG_RASTERIZATIONS_PER_FRAME: u32 = 64;

/// Most image cache entries any atlas budget may hold (`image_entry_count_max`).
pub const MAX_IMAGE_ENTRIES: u32 = 4_096;

/// Longest image path any atlas budget may accept: Linux's `PATH_MAX`.
pub const MAX_IMAGE_PATH_BYTES: u32 = 4_096;

/// Frames whose atlas items count as in use at once: the frame being built.
/// An item an open frame used is never evicted, so the SVG and image caches
/// must hold this many frames of icons and images, and each atlas this many
/// frames of shelves. Build and draw overlap would make it 2 (one frame
/// building, one drawing); GPU frames in flight do not extend it, because
/// uploads are ordered after earlier draws. The EVE host also
/// protects the frame on screen (`AtlasUploads.protectShownFrame`), so its
/// `EveLimits.check` asks the caches for two frames.
pub const atlas_open_frame_count_max: u32 = 1;

/// Windows one app opens: one. The platform window
/// registry and the atlas upload journal's consumers are sized from it; a
/// multi-window core would make it a `WindowLimits` field.
pub const window_count_max: u32 = 1;

/// Image decodes the worker holds in the completion ring at once: it decodes
/// one request at a time and waits for the drain to take the result.
pub const image_decode_outstanding_max: u32 = 1;

comptime {
    assert(window_count_max == 1);
    assert(image_decode_outstanding_max == 1);
    assert(MAX_IMAGE_DECODE_BYTES > MAX_ATLAS_SIZE * MAX_ATLAS_SIZE * 4);
    assert(MAX_SVG_RASTERIZATIONS_PER_FRAME <= MAX_SVG_ENTRIES);
    assert(MAX_IMAGE_REQUESTS <= MAX_IMAGE_ENTRIES);
    assert(atlas_open_frame_count_max >= 1);
    // The ceiling profile must satisfy its own entry relationships.
    assert(atlas_open_frame_count_max * MAX_SVGS_PER_FRAME <= MAX_SVG_ENTRIES);
    assert(atlas_open_frame_count_max * MAX_IMAGES_PER_FRAME <= MAX_IMAGE_ENTRIES);
    assert(MAX_ATLAS_UPLOAD_BYTES_PER_FRAME * 3 == MAX_ATLAS_SIZE * MAX_ATLAS_SIZE * 9);
}

/// The complete resource budget an application declares at `gooey.App(...)`
/// (`.limits = ...`). Every per-window subsystem sizes its
/// storage from this value during initialization and never grows afterwards.
///
/// Each subsystem owns one nested struct so later budgets (layout, a11y, text,
/// widgets) are added as new fields beside `paint`, `window` and `frame` without
/// reshaping the type. Fields have no defaults and there is no default profile:
/// callers pick one of the named profiles or spell out every capacity, so no
/// capacity hides in a leaf default.
///
/// The rungs, smallest first, and the example class each was sized from
/// (measured peaks with their headroom):
/// `nano` (counter, actions, animation), `small` (todo, layout, accessible-form),
/// `standard` (showcase, data-table, spaceship, dashboard), `large` (lucide-demo,
/// images, mesh stress) and `ceiling` (every framework maximum). Beside the
/// rungs, `embedded` sizes board-class apps (logo) for a 1024x600-class
/// panel at scale 1: a smaller window than `nano` and a larger image atlas.
pub const ResourceLimits = struct {
    paint: PaintLimits,
    window: WindowLimits,
    frame: FrameLimits,
    atlas: AtlasLimits,
    build: BuildLimits,
    records: RecordLimits,
    retained: RetainedLimits,
    events: EventLimits,
    text: TextLimits,
    entities: EntityLimits,
    a11y: A11yLimits,

    /// Every profile name `gooey.App(.., .{ .limits = ... })` accepts: the rungs,
    /// then `embedded`. Each profile's `text.fonts` is the `FontLimits` profile
    /// of the same name.
    pub const profile_names = rung_names ++ [_][]const u8{"embedded"};

    /// The desktop ladder, smallest first: no rung offers less than the one
    /// below it for any paint, window, frame, or atlas capacity. `embedded`
    /// is not a rung, because it trades window size for image atlas.
    pub const rung_names = [_][]const u8{ "nano", "small", "standard", "large", "ceiling" };

    /// Board-class apps on a 1024x600-class panel at scale 1 (fbdev, eve):
    /// `nano`'s element and event budgets, paint counts that fit one EVE
    /// display list (`PaintLimits.embedded`), a 1280x800 framebuffer, two
    /// faces, and a 384² image atlas for a logo.
    /// See `AtlasLimits.embedded` for why the image atlas is that size.
    pub const embedded: ResourceLimits = .{
        .paint = PaintLimits.embedded,
        .window = WindowLimits.embedded,
        .frame = FrameLimits.nano,
        .atlas = AtlasLimits.embedded,
        .build = BuildLimits.nano,
        .records = RecordLimits.nano,
        .retained = RetainedLimits.nano,
        .events = EventLimits.nano,
        .text = TextLimits.embedded,
        .entities = EntityLimits.nano,
        .a11y = A11yLimits.nano,
    };

    /// Counter-class apps: a few dozen elements and one face, two frames in flight.
    pub const nano: ResourceLimits = .{
        .paint = PaintLimits.nano,
        .window = WindowLimits.nano,
        .frame = FrameLimits.nano,
        .atlas = AtlasLimits.nano,
        .build = BuildLimits.nano,
        .records = RecordLimits.nano,
        .retained = RetainedLimits.nano,
        .events = EventLimits.nano,
        .text = TextLimits.nano,
        .entities = EntityLimits.nano,
        .a11y = A11yLimits.nano,
    };

    /// Single-screen forms and lists, two frames in flight.
    pub const small: ResourceLimits = .{
        .paint = PaintLimits.small,
        .window = WindowLimits.small,
        .frame = FrameLimits.small,
        .atlas = AtlasLimits.small,
        .build = BuildLimits.small,
        .records = RecordLimits.small,
        .retained = RetainedLimits.small,
        .events = EventLimits.small,
        .text = TextLimits.small,
        .entities = EntityLimits.small,
        .a11y = A11yLimits.small,
    };

    /// Ordinary multi-panel UI apps. See `PaintLimits.standard`.
    pub const standard: ResourceLimits = .{
        .paint = PaintLimits.standard,
        .window = WindowLimits.standard,
        .frame = FrameLimits.standard,
        .atlas = AtlasLimits.standard,
        .build = BuildLimits.standard,
        .records = RecordLimits.standard,
        .retained = RetainedLimits.standard,
        .events = EventLimits.standard,
        .text = TextLimits.standard,
        .entities = EntityLimits.standard,
        .a11y = A11yLimits.standard,
    };

    /// Dense-content apps: big tables, treemaps, full-screen editors, charts,
    /// hundreds of icons, large image atlases.
    pub const large: ResourceLimits = .{
        .paint = PaintLimits.large,
        .window = WindowLimits.large,
        .frame = FrameLimits.large,
        .atlas = AtlasLimits.large,
        .build = BuildLimits.large,
        .records = RecordLimits.large,
        .retained = RetainedLimits.large,
        .events = EventLimits.large,
        .text = TextLimits.large,
        .entities = EntityLimits.large,
        .a11y = A11yLimits.large,
    };

    /// Every capacity at its framework ceiling. For stress tests and benchmarks,
    /// not an app profile: `gooey.App` rejects it at compile time, since an app
    /// budget must leave the debugger overlay's headroom below every ceiling.
    /// The aggregate mesh geometry ceilings are
    /// validation bounds, not a renderable reservation: the window's mesh points
    /// alone are about 4.5 GiB of virtual memory, and GPU renderers reserve
    /// geometry per frame in flight (Metal about 62 GiB per frame here), so a
    /// window that renders must lower them.
    pub const ceiling: ResourceLimits = .{
        .paint = PaintLimits.ceiling,
        .window = WindowLimits.ceiling,
        .frame = FrameLimits.ceiling,
        .atlas = AtlasLimits.ceiling,
        .build = BuildLimits.ceiling,
        .records = RecordLimits.ceiling,
        .retained = RetainedLimits.ceiling,
        .events = EventLimits.ceiling,
        .text = TextLimits.ceiling,
        .entities = EntityLimits.ceiling,
        .a11y = A11yLimits.ceiling,
    };

    /// First violated rule, or null when the budget is valid. Shared by the
    /// comptime `validate` and the runtime initialization checks.
    pub fn check(self: *const ResourceLimits) ?Violation {
        if (self.paint.check()) |violation| return violation;
        if (self.window.check()) |violation| return violation;
        if (self.frame.check()) |violation| return violation;
        if (self.atlas.check()) |violation| return violation;
        if (checkCeilings(BuildLimits, .build, &self.build)) |violation| return violation;
        if (checkCeilings(RecordLimits, .records, &self.records)) |violation| return violation;
        if (checkCeilings(RetainedLimits, .retained, &self.retained)) |violation| return violation;
        if (checkCeilings(EventLimits, .events, &self.events)) |violation| return violation;
        if (self.text.check()) |violation| return violation;
        if (checkCeilings(EntityLimits, .entities, &self.entities)) |violation| return violation;
        if (checkCeilings(A11yLimits, .a11y, &self.a11y)) |violation| return violation;
        return self.checkCoreRelationships();
    }

    /// Rules between the core's budgets. A hit record, a handler, a layer and a
    /// level of box nesting each belong to an element, so none can outnumber
    /// elements.
    fn checkCoreRelationships(self: *const ResourceLimits) ?Violation {
        const element_count = self.build.element_count_frame_max;
        if (self.records.hit_record_count_frame_max > element_count) {
            return relationship(
                .records,
                "hit_record_count_frame_max",
                self.records.hit_record_count_frame_max,
                element_count,
            );
        }
        if (self.records.handler_count_frame_max > element_count * handler_count_element_max) {
            return relationship(
                .records,
                "handler_count_frame_max",
                self.records.handler_count_frame_max,
                element_count * handler_count_element_max,
            );
        }
        if (self.build.key_count_frame_max > element_count) {
            return relationship(
                .build,
                "key_count_frame_max",
                self.build.key_count_frame_max,
                element_count,
            );
        }
        if (self.build.layer_count_frame_max > element_count) {
            return relationship(
                .build,
                "layer_count_frame_max",
                self.build.layer_count_frame_max,
                element_count,
            );
        }
        if (self.build.box_depth_max > element_count) {
            return relationship(.build, "box_depth_max", self.build.box_depth_max, element_count);
        }
        if (self.checkA11yRelationships()) |violation| return violation;
        if (self.checkAtlasCacheRelationships()) |violation| return violation;
        if (self.text.preedit_bytes_max > self.events.text_bytes_max) {
            return relationship(
                .text,
                "preedit_bytes_max",
                self.text.preedit_bytes_max,
                self.events.text_bytes_max,
            );
        }
        if (self.checkEventRelationships()) |violation| return violation;
        if (self.records.paint_record_count_frame_max < element_count) {
            return .{
                .budget = .records,
                .field = "paint_record_count_frame_max",
                .rule = .below_relationship,
                .value = self.records.paint_record_count_frame_max,
                .bound = element_count,
            };
        }
        return null;
    }

    /// Every icon and image an open frame draws stays cached, so the SVG and
    /// image caches hold `atlas_open_frame_count_max` frames of them.
    fn checkAtlasCacheRelationships(self: *const ResourceLimits) ?Violation {
        const svg_bound = atlas_open_frame_count_max * self.paint.svg_count_frame_max;
        if (self.atlas.svg_entry_count_max < svg_bound) {
            return .{
                .budget = .atlas,
                .field = "svg_entry_count_max",
                .rule = .below_relationship,
                .value = self.atlas.svg_entry_count_max,
                .bound = svg_bound,
            };
        }
        const image_bound = atlas_open_frame_count_max * self.paint.image_count_frame_max;
        if (self.atlas.image_entry_count_max < image_bound) {
            return .{
                .budget = .atlas,
                .field = "image_entry_count_max",
                .rule = .below_relationship,
                .value = self.atlas.image_entry_count_max,
                .bound = image_bound,
            };
        }
        return null;
    }

    /// Each pending dialog completes into the ring beside the image
    /// worker's one outstanding decode.
    fn checkEventRelationships(self: *const ResourceLimits) ?Violation {
        // The ring holds every completion that can be outstanding at once:
        // each pending dialog, the image worker's one decode, each held job
        // result slot, and each job's end.
        const completion_bound = self.events.dialog_count_max + image_decode_outstanding_max +
            self.events.job_result_count_max + self.events.job_count_max;
        if (self.events.completion_count_max < completion_bound) {
            return .{
                .budget = .events,
                .field = "completion_count_max",
                .rule = .below_relationship,
                .value = self.events.completion_count_max,
                .bound = completion_bound,
            };
        }
        if (self.events.queue_count_max < input_burst_count_max) {
            return .{
                .budget = .events,
                .field = "queue_count_max",
                .rule = .below_relationship,
                .value = self.events.queue_count_max,
                .bound = input_burst_count_max,
            };
        }
        return null;
    }

    /// Every accessibility node is an element, and a node's value fits the
    /// frame's text bytes.
    fn checkA11yRelationships(self: *const ResourceLimits) ?Violation {
        const element_count = self.build.element_count_frame_max;
        if (self.a11y.element_count_max > element_count) {
            return relationship(
                .a11y,
                "element_count_max",
                self.a11y.element_count_max,
                element_count,
            );
        }
        if (self.a11y.value_bytes_max > self.build.text_bytes_frame_max) {
            return relationship(
                .a11y,
                "value_bytes_max",
                self.a11y.value_bytes_max,
                self.build.text_bytes_frame_max,
            );
        }
        return null;
    }

    /// Runtime counterpart of `validate` for budgets that are not comptime-known
    /// (direct `runCx` / `openWindow` callers). An invalid budget is a
    /// programmer error, so it stops initialization with the broken rule.
    pub fn assertValid(self: *const ResourceLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.{t}.{s} = {d}: rule {t}, bound {d}", .{
                violation.budget,
                violation.field,
                violation.value,
                violation.rule,
                violation.bound,
            });
        }
    }

    /// Reject an invalid budget at compile time with a message naming the
    /// field, its value, and the bound it broke.
    pub fn validate(comptime self: ResourceLimits) void {
        comptime {
            if (self.check()) |violation| @compileError(violation.describe());
        }
    }
};

/// Per-window, per-frame paint capacities. Each window's packed frame reserves
/// its quad, sprite, mesh and edge pools from these counts, and its two records
/// frames reserve the mesh points (`paintBytes`). GPU renderers size their
/// instance and mesh buffers from the same packed pools per frame in flight.
pub const PaintLimits = struct {
    quad_count_frame_max: u32,
    shadow_count_frame_max: u32,
    glyph_count_frame_max: u32,
    svg_count_frame_max: u32,
    image_count_frame_max: u32,
    /// Path instances; the parallel gradient array has the same capacity.
    path_count_frame_max: u32,
    polyline_count_frame_max: u32,
    point_cloud_count_frame_max: u32,
    /// Mesh points submitted per frame, summed over draws, one count per kind:
    /// triangle vertices, polyline points and point-cloud points. One draw may
    /// use all of its kind's count; nothing bounds a single draw more tightly.
    /// The counts are independent of draw budgets and of backend expansion.
    path_vertex_count_frame_max: u32,
    polyline_point_count_frame_max: u32,
    point_count_frame_max: u32,
    clip_depth_max: u32,

    /// Counter-class apps. Largest measured peaks in the class (counter,
    /// dynamic-counters, actions, animation, file-dialog): quads 11, glyphs 118,
    /// no shadows, SVGs, images, paths or geometry. Headroom about 23x for quads;
    /// 1,024 glyphs is the floor because one shaped run is inserted whole. Mesh
    /// geometry allows a few small icons or one sparkline. About 203 KiB per window.
    pub const nano: PaintLimits = .{
        .quad_count_frame_max = 256,
        .shadow_count_frame_max = 16,
        .glyph_count_frame_max = 1_024,
        .svg_count_frame_max = 16,
        .image_count_frame_max = 4,
        .path_count_frame_max = 16,
        .polyline_count_frame_max = 4,
        .point_cloud_count_frame_max = 4,
        .path_vertex_count_frame_max = 1_024,
        .polyline_point_count_frame_max = 1_024,
        .point_count_frame_max = 1_024,
        .clip_depth_max = 8,
    };

    /// Board-class apps (`ResourceLimits.embedded`): `nano`'s glyphs and
    /// icons, with every other count cut so the fullest frame fits the EVE
    /// display list's 1536 commands (`EveLimits.paintWordsMin`: 1496). The
    /// 1,024 glyphs alone take 1,024. Measured peaks: counter 11 quads and
    /// 118 glyphs (149 commands), the SWAPI board app 198 commands, the logo
    /// example 1 image. Images: 8 a frame, so the cache holds the two frames
    /// EVE protects.
    pub const embedded: PaintLimits = .{
        .quad_count_frame_max = 128,
        .shadow_count_frame_max = 8,
        .glyph_count_frame_max = 1_024,
        .svg_count_frame_max = 16,
        .image_count_frame_max = 8,
        .path_count_frame_max = 16,
        .polyline_count_frame_max = 4,
        .point_cloud_count_frame_max = 4,
        .path_vertex_count_frame_max = 1_024,
        .polyline_point_count_frame_max = 64,
        .point_count_frame_max = 64,
        .clip_depth_max = 8,
    };

    /// Single-screen apps. Largest measured peaks in the class (todo, layout,
    /// nested-overlay, drag-drop, accessible-form, code-editor): quads 40,
    /// shadows 2, glyphs 358, SVGs 2, no images, paths or geometry. Headroom
    /// about 25x for quads and 11x for glyphs. About 1.1 MiB per window.
    pub const small: PaintLimits = .{
        .quad_count_frame_max = 1_024,
        .shadow_count_frame_max = 64,
        .glyph_count_frame_max = 4_096,
        .svg_count_frame_max = 128,
        .image_count_frame_max = 32,
        .path_count_frame_max = 128,
        .polyline_count_frame_max = 32,
        .point_cloud_count_frame_max = 32,
        .path_vertex_count_frame_max = 8_192,
        .polyline_point_count_frame_max = 8_192,
        .point_count_frame_max = 8_192,
        .clip_depth_max = 16,
    };

    /// Ordinary multi-panel apps. Largest measured peaks in the class (showcase,
    /// data-table, spaceship, dashboard) while scrolling, hovering and switching
    /// tabs: quads 102 (spaceship), shadows 3, glyphs 1,370 (showcase), SVGs 26,
    /// images 1, paths 256, polylines 5, clip depth 2.
    /// Quads and glyphs keep 40x and 6x headroom; lucide-demo's 780 quads and 480
    /// SVGs are on `large`.
    /// Geometry: dashboard needs 780 path vertices and 24 line points, so the
    /// 4x cut still leaves at least 20x; the mesh stress
    /// test (an 8,192-point line, 4,096 points of each kind) ran on `large`.
    /// About 2.8 MiB per window.
    pub const standard: PaintLimits = .{
        .quad_count_frame_max = 4_096,
        .shadow_count_frame_max = 512,
        .glyph_count_frame_max = 8_192,
        .svg_count_frame_max = 1_024,
        .image_count_frame_max = 256,
        .path_count_frame_max = 1_024,
        .polyline_count_frame_max = 256,
        .point_cloud_count_frame_max = 256,
        .path_vertex_count_frame_max = 16_384,
        .polyline_point_count_frame_max = 32_768,
        .point_count_frame_max = 16_384,
        .clip_depth_max = 16,
    };

    /// Heavy apps: lucide-demo (780 quads, 480 SVGs), the images example, and the
    /// mesh stress fixtures. 16x `standard` for geometry and, for full-screen
    /// text, the glyph ceiling less the 300 glyphs a safe build reserves for the
    /// debugger overlay, which an app budget must leave
    /// below every ceiling. About 33.7 MiB per window, half of it mesh points.
    pub const large: PaintLimits = .{
        .quad_count_frame_max = 32_768,
        .shadow_count_frame_max = 2_048,
        .glyph_count_frame_max = 65_236,
        .svg_count_frame_max = 4_096,
        .image_count_frame_max = 1_024,
        .path_count_frame_max = 4_096,
        .polyline_count_frame_max = 1_024,
        .point_cloud_count_frame_max = 1_024,
        .path_vertex_count_frame_max = 262_144,
        .polyline_point_count_frame_max = 524_288,
        .point_count_frame_max = 262_144,
        .clip_depth_max = 32,
    };

    /// The framework ceilings themselves; the upper bound for every budget.
    pub const ceiling: PaintLimits = .{
        .quad_count_frame_max = MAX_QUADS_PER_FRAME,
        .shadow_count_frame_max = MAX_SHADOWS_PER_FRAME,
        .glyph_count_frame_max = MAX_GLYPHS_PER_FRAME,
        .svg_count_frame_max = MAX_SVGS_PER_FRAME,
        .image_count_frame_max = MAX_IMAGES_PER_FRAME,
        .path_count_frame_max = MAX_PATHS_PER_FRAME,
        .polyline_count_frame_max = MAX_POLYLINES_PER_FRAME,
        .point_cloud_count_frame_max = MAX_POINT_CLOUDS_PER_FRAME,
        .path_vertex_count_frame_max = MAX_PATHS_PER_FRAME * MAX_PATH_VERTICES,
        .polyline_point_count_frame_max = 32 * 1024 * 1024,
        .point_count_frame_max = 256 * 1024 * 1024,
        .clip_depth_max = MAX_CLIP_STACK_DEPTH,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`, and
    /// the cross-limit relationships below must hold.
    pub fn check(self: *const PaintLimits) ?Violation {
        inline for (@typeInfo(PaintLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .paint,
                    .field = field_name,
                    .rule = .zero,
                    .value = value,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .paint,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        // One shaped text run is inserted whole, so a frame must hold at least one.
        if (self.glyph_count_frame_max < MAX_GLYPHS_PER_RUN) {
            return .{
                .budget = .paint,
                .field = "glyph_count_frame_max",
                .rule = .below_relationship,
                .value = self.glyph_count_frame_max,
                .bound = MAX_GLYPHS_PER_RUN,
            };
        }
        return null;
    }

    /// Bytes one window reserves for this budget: the packed frame's quad,
    /// sprite, mesh and edge pools (`packed_frame.paintBytes`) and the mesh
    /// points of its two records frames. The wrapped lines this budget's glyph
    /// count bounds are counted with the layout arena. Every pool comes from
    /// fresh pages, so this bounds virtual memory; resident memory follows
    /// what frames write.
    pub fn paintBytes(self: *const PaintLimits) u64 {
        const packed_bytes = packed_frame.paintBytes(self);
        const point_bytes = @as(u64, packed_frame.meshPointCapacity(self)) *
            @sizeOf(packed_frame.MeshPoint);
        const bytes = packed_bytes + 2 * point_bytes;
        assert(bytes > packed_bytes);
        return bytes;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
        assert(embedded.check() == null);
    }
};

/// Per-window framebuffer bounds, in physical pixels.
///
/// The CPU renderer backends (`-Dlinux-backend=wayland_cpu` and `fbdev`) reserve
/// their framebuffers and raster scratch for this size while the window
/// initializes and never resize them. A Wayland window the
/// compositor makes larger renders at a reduced device scale, which the
/// compositor scales up; an fbdev panel larger than the budget fails
/// initialization. The GPU backends size their swapchains from the driver and
/// do not read these fields yet.
pub const WindowLimits = struct {
    framebuffer_width_max: u32,
    framebuffer_height_max: u32,

    /// Counter-class windows up to 1,280 x 800 points on a 2x Retina display (the
    /// budget is physical pixels). Two `wl_shm` frames map 31.3 MiB of virtual
    /// memory; pages become resident only for the window's actual size.
    pub const nano: WindowLimits = .{
        .framebuffer_width_max = 2560,
        .framebuffer_height_max = 1600,
    };

    /// Board panels up to 1,280 x 800 at scale 1, the 1024x600 and 800x480
    /// classes included. The fbdev back buffer is 3.9 MiB.
    pub const embedded: WindowLimits = .{
        .framebuffer_width_max = 1280,
        .framebuffer_height_max = 800,
    };

    /// Single-screen windows up to 1,920 x 1,080 points at 2x. Two `wl_shm` frames
    /// map 63.3 MiB of virtual memory; resident pages follow the window size.
    pub const small: WindowLimits = .{
        .framebuffer_width_max = 3840,
        .framebuffer_height_max = 2160,
    };

    /// Full screen at full scale on a 4K UHD display (3,840 wide) and on a 16"
    /// MacBook Pro (3,456 x 2,234). Two `wl_shm` frames
    /// map 70.3 MiB per window; pages are touched, and so resident, only for the
    /// window's actual size.
    pub const standard: WindowLimits = .{
        .framebuffer_width_max = 3840,
        .framebuffer_height_max = 2400,
    };

    /// 5K, for full-screen windows on high-density desktop panels.
    pub const large: WindowLimits = .{
        .framebuffer_width_max = 5120,
        .framebuffer_height_max = 2880,
    };

    /// The framework ceilings themselves (8K UHD).
    pub const ceiling: WindowLimits = .{
        .framebuffer_width_max = MAX_FRAMEBUFFER_WIDTH,
        .framebuffer_height_max = MAX_FRAMEBUFFER_HEIGHT,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`.
    pub fn check(self: *const WindowLimits) ?Violation {
        inline for (@typeInfo(WindowLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .window,
                    .field = field_name,
                    .rule = .zero,
                    .value = value,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .window,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        return null;
    }

    /// Pixels in the largest framebuffer the budget allows.
    pub fn framebufferPixelCountMax(self: *const WindowLimits) u64 {
        assert(self.framebuffer_width_max <= MAX_FRAMEBUFFER_WIDTH);
        assert(self.framebuffer_height_max <= MAX_FRAMEBUFFER_HEIGHT);
        return @as(u64, self.framebuffer_width_max) * self.framebuffer_height_max;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
        assert(embedded.check() == null);
    }
};

/// Frames a window's renderer keeps in flight. Every per-frame GPU resource is
/// reserved once per frame in flight at init: the Vulkan host and mesh pools,
/// descriptor sets, command buffers and fences, and the Metal instance and mesh
/// rings. It also sets the Vulkan swapchain's image count: the driver's minimum
/// plus one image per frame in flight above two (the driver minimum plus one, as
/// before, at three). Metal keeps three drawables in every profile, because two
/// stall `nextDrawable` (`metal/renderer.zig`). The CPU renderer draws synchronously,
/// so its two `wl_shm` slots, one the compositor reads and one being drawn, are
/// the minimum here and do not change with the budget.
///
/// Two frames halve the bound rings at `nano` and `small`, whose apps are not
/// GPU-bound, at the cost of less CPU/GPU overlap.
/// `standard` and above keep three.
pub const FrameLimits = struct {
    in_flight_count: u32,

    pub const nano: FrameLimits = .{ .in_flight_count = 2 };
    pub const small: FrameLimits = .{ .in_flight_count = 2 };
    pub const standard: FrameLimits = .{ .in_flight_count = 3 };
    pub const large: FrameLimits = .{ .in_flight_count = 3 };
    pub const ceiling: FrameLimits = .{ .in_flight_count = MAX_FRAMES_IN_FLIGHT };

    /// First violated rule, or null. The count must be in
    /// `MIN_FRAMES_IN_FLIGHT..=MAX_FRAMES_IN_FLIGHT`.
    pub fn check(self: *const FrameLimits) ?Violation {
        if (self.in_flight_count < MIN_FRAMES_IN_FLIGHT) {
            return .{
                .budget = .frame,
                .field = "in_flight_count",
                .rule = .below_relationship,
                .value = self.in_flight_count,
                .bound = MIN_FRAMES_IN_FLIGHT,
            };
        }
        if (self.in_flight_count > MAX_FRAMES_IN_FLIGHT) {
            return .{
                .budget = .frame,
                .field = "in_flight_count",
                .rule = .above_ceiling,
                .value = self.in_flight_count,
                .bound = MAX_FRAMES_IN_FLIGHT,
            };
        }
        return null;
    }

    comptime {
        assert(MIN_FRAMES_IN_FLIGHT <= MAX_FRAMES_IN_FLIGHT);
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

/// Per-application atlas budgets: the glyph, SVG, and image atlases are square
/// textures of a fixed side, reserved once at initialization and never grown.
/// When one is full it evicts its least recently used shelf;
/// items used in the current frame are never evicted, and a frame whose live
/// set does not fit fails fast with the atlas name.
///
/// GPU backends keep no CPU copy of atlas pixels. Rasterized pixels travel to
/// the texture through one bounded staging journal of `upload_bytes_frame_max`
/// bytes shared by the three atlases; work past it waits for the next frame.
/// The CPU renderer keeps its atlases in CPU memory, because they are its
/// textures.
pub const AtlasLimits = struct {
    /// Rasterized bytes all three atlases may stage for upload in one frame.
    /// GPU backends reserve this much staging per frame in flight.
    upload_bytes_frame_max: u32,
    /// Glyph atlas side in pixels (R8, 1 B per pixel).
    text_size: u32,
    /// SVG icon atlas side in pixels (RGBA, 4 B per pixel).
    svg_size: u32,
    /// Image atlas side in pixels (RGBA, 4 B per pixel).
    image_size: u32,
    /// Largest SVG icon side in device pixels; sizes the SVG raster buffer.
    svg_icon_size_max: u32,
    /// Most bytes of path data one SVG icon may carry. A longer path fails
    /// fast naming this field; it also sizes the SVG raster scratch.
    svg_path_bytes_max: u32,
    /// Most vertices one SVG icon may flatten to at its device size, which
    /// sizes the software rasterizer's scratch (Linux and Windows). An icon
    /// that needs more fails fast naming this field.
    svg_path_vertex_count_max: u32,
    /// Images that may wait for the decode worker or stay remembered as
    /// failed at once (`core/images.zig`). One more fails fast naming this.
    image_request_count_max: u32,
    /// Bytes the decode worker reserves at init for one image: its file
    /// followed by its decoded RGBA pixels. A larger image fails fast naming
    /// this field. Fresh pages, so only what a decode writes is resident.
    /// Each profile holds one image as wide as its image atlas, `image_size²`
    /// RGBA, plus a file of up to half that again: the images example's
    /// 512² logo is a 1 MiB decode from a small file.
    image_decode_bytes_max: u32,
    /// Rasterized icons the SVG cache keeps, one per path, size, fill and
    /// stroke. A full cache drops icons whose atlas shelf was evicted. Every
    /// icon drawn by an open frame stays, so this is at least
    /// `atlas_open_frame_count_max × paint.svg_count_frame_max`.
    svg_entry_count_max: u32,
    /// SVG icons rasterized per frame. An icon past it is skipped this frame
    /// and drawn by a later one, so a screen of new icons fills in over
    /// several frames instead of stalling one. At most `svg_entry_count_max`.
    svg_rasterization_count_frame_max: u32,
    /// Decoded images the image cache keeps. Every image drawn by an open
    /// frame and every landed decode needs one, so this is at least
    /// `atlas_open_frame_count_max × paint.image_count_frame_max` and at least
    /// `image_request_count_max`.
    image_entry_count_max: u32,
    /// Longest path `Painter.image` accepts; each image request entry
    /// reserves this many bytes. A longer path fails fast naming this field.
    image_path_bytes_max: u32,

    /// Cache peaks measured over every example: lucide-demo
    /// keeps 1,668 SVG icons at `large` and the images example 18 images. The
    /// entry counts sit at or above each profile's per-frame icon and image
    /// budgets, which they must hold. Four rasterizations a frame keep a
    /// frame's icon work near 2 to 8 ms; `large` takes 16, so lucide-demo's
    /// icons fill in within about 1.7 s instead of 7 s.
    ///
    /// Atlas area follows the same open-frame rule as the caches: eviction
    /// frees whole shelves, so `atlas_open_frame_count_max` frames of a
    /// frame's worst-case shelf area must fit each atlas side. Shelf area
    /// depends on content, so this is a sizing rule, checked at run time by
    /// the atlas's live-set fail-fast (the `atlas-live-set` check).
    ///
    /// Counter-class apps: counter's glyphs hold 144 of 512 text-atlas rows at
    /// 1x and 280 at 2x (measured with shelf packing), and no nano example draws
    /// icons or images. Textures: 0.25 + 0.25 + 0.25 MiB.
    /// A full nano atlas set uploads within 3 frames. SVG paths allow about
    /// twice Lucide's heaviest icon at each profile's largest icon side.
    pub const nano: AtlasLimits = .{
        .upload_bytes_frame_max = 256 * 1024,
        .text_size = 512,
        .svg_size = 256,
        .image_size = 256,
        .svg_icon_size_max = 64,
        .svg_path_bytes_max = 2 * 1024,
        .svg_path_vertex_count_max = 4 * 1024,
        .image_request_count_max = 4,
        .image_decode_bytes_max = 512 * 1024,
        .svg_entry_count_max = 64,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 8,
        .image_path_bytes_max = 1_024,
    };

    /// Board-class apps (`ResourceLimits.embedded`): `nano`'s glyph and icon
    /// atlases, and a 384² image atlas: a logo up to 382 px a side (each
    /// atlas item carries a 1 px border), such as the logo example's 320x200.
    /// The EVE backend mirrors the image atlas into the chip's 1 MiB `RAM_G`
    /// at 2 B per pixel (288 KiB), which leaves ten 64 KiB glyph-cell pages;
    /// a 512² atlas would leave seven. One frame stages one atlas-wide image.
    /// Textures: 0.25 + 0.25 + 0.56 MiB.
    pub const embedded: AtlasLimits = .{
        .upload_bytes_frame_max = 384 * 384 * 4,
        .text_size = 512,
        .svg_size = 256,
        .image_size = 384,
        .svg_icon_size_max = 64,
        .svg_path_bytes_max = 2 * 1024,
        .svg_path_vertex_count_max = 4 * 1024,
        .image_request_count_max = 4,
        .image_decode_bytes_max = 384 * 384 * 4 * 3 / 2,
        .svg_entry_count_max = 64,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 16,
        .image_path_bytes_max = 1_024,
    };

    /// Forms and lists: todo holds 48 of 1024 text rows at 1x and 120 at 2x.
    /// Textures: 1 + 1 + 1 MiB.
    pub const small: AtlasLimits = .{
        .upload_bytes_frame_max = 1024 * 1024,
        .text_size = 1_024,
        .svg_size = 512,
        .image_size = 512,
        .svg_icon_size_max = 128,
        .svg_path_bytes_max = 4 * 1024,
        .svg_path_vertex_count_max = 8 * 1024,
        .image_request_count_max = 8,
        .image_decode_bytes_max = 2 * 1024 * 1024,
        .svg_entry_count_max = 256,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 32,
        .image_path_bytes_max = 1_024,
    };

    /// The glyph atlas is 2048² for Retina display text: a frame of 70 distinct
    /// 52 pt glyphs at 2x needs more than 1024 shelf rows once glyphs are cached
    /// per subpixel variant. Showcase holds 132 glyph rows at 1x and 480 at 2x,
    /// 44 SVG rows, and 324 of 1024 image rows. Textures: 4 + 4 + 4 MiB. A full
    /// 1024² RGBA atlas uploads in 4 frames.
    pub const standard: AtlasLimits = .{
        .upload_bytes_frame_max = 1024 * 1024,
        .text_size = 2_048,
        .svg_size = 1_024,
        .image_size = 1_024,
        .svg_icon_size_max = 256,
        .svg_path_bytes_max = 8 * 1024,
        .svg_path_vertex_count_max = 16 * 1024,
        .image_request_count_max = 16,
        .image_decode_bytes_max = 8 * 1024 * 1024,
        .svg_entry_count_max = 1_024,
        .svg_rasterization_count_frame_max = 4,
        .image_entry_count_max = 256,
        .image_path_bytes_max = 1_024,
    };

    /// lucide-demo's visible icons hold 520 of 2048 SVG rows at 2x, and the
    /// images example's logo copies hold 1032 of 2048 image rows at 1x and 2x.
    /// The image atlas was 4096² (64 MiB), which cost about 65 MB per window
    /// on macOS for space no example used. Textures: 16 + 16 + 16 MiB.
    pub const large: AtlasLimits = .{
        .upload_bytes_frame_max = 16 * 1024 * 1024,
        .text_size = 4_096,
        .svg_size = 2_048,
        .image_size = 2_048,
        .svg_icon_size_max = 256,
        .svg_path_bytes_max = 16 * 1024,
        .svg_path_vertex_count_max = 16 * 1024,
        .image_request_count_max = 64,
        .image_decode_bytes_max = 24 * 1024 * 1024,
        .svg_entry_count_max = 4_096,
        .svg_rasterization_count_frame_max = 16,
        .image_entry_count_max = 1_024,
        .image_path_bytes_max = 1_024,
    };

    /// The framework ceilings themselves. Textures: 16 + 64 + 64 MiB.
    pub const ceiling: AtlasLimits = .{
        .upload_bytes_frame_max = MAX_ATLAS_UPLOAD_BYTES_PER_FRAME,
        .text_size = MAX_ATLAS_SIZE,
        .svg_size = MAX_ATLAS_SIZE,
        .image_size = MAX_ATLAS_SIZE,
        .svg_icon_size_max = MAX_SVG_ICON_SIZE,
        .svg_path_bytes_max = MAX_SVG_PATH_BYTES,
        .svg_path_vertex_count_max = MAX_SVG_PATH_VERTEX_COUNT,
        .image_request_count_max = MAX_IMAGE_REQUESTS,
        .image_decode_bytes_max = MAX_IMAGE_DECODE_BYTES,
        .svg_entry_count_max = MAX_SVG_ENTRIES,
        .svg_rasterization_count_frame_max = MAX_SVG_RASTERIZATIONS_PER_FRAME,
        .image_entry_count_max = MAX_IMAGE_ENTRIES,
        .image_path_bytes_max = MAX_IMAGE_PATH_BYTES,
    };

    /// First violated rule, or null. Every field must be in `1..=ceiling`;
    /// atlas sides are multiples of `MIN_ATLAS_SIZE`; the largest icon fits its
    /// atlas; and one frame can stage the largest glyph and the largest icon.
    pub fn check(self: *const AtlasLimits) ?Violation {
        inline for (@typeInfo(AtlasLimits).@"struct".field_names) |field_name| {
            const value: u32 = @field(self, field_name);
            const bound: u32 = @field(ceiling, field_name);
            if (value == 0) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .zero,
                    .value = 0,
                    .bound = 1,
                };
            }
            if (value > bound) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        inline for (.{ "text_size", "svg_size", "image_size" }) |field_name| {
            const value: u32 = @field(self, field_name);
            if (value % MIN_ATLAS_SIZE != 0) {
                return .{
                    .budget = .atlas,
                    .field = field_name,
                    .rule = .not_multiple,
                    .value = value,
                    .bound = MIN_ATLAS_SIZE,
                };
            }
        }
        return self.checkRelationships();
    }

    /// Runtime check for budgets that are not comptime-known.
    pub fn assertValid(self: *const AtlasLimits) void {
        if (self.check()) |violation| {
            std.debug.panic("invalid ResourceLimits.atlas.{s} = {d}: rule {t}, bound {d}", .{
                violation.field,
                violation.value,
                violation.rule,
                violation.bound,
            });
        }
    }

    /// Cross-field rules. Every atlas item carries a 1 px border on each side.
    /// A frame rasterizes at most the icons the cache holds, and every landed
    /// image request needs a cache entry.
    fn checkRelationships(self: *const AtlasLimits) ?Violation {
        if (self.svg_rasterization_count_frame_max > self.svg_entry_count_max) {
            return relationship(
                .atlas,
                "svg_rasterization_count_frame_max",
                self.svg_rasterization_count_frame_max,
                self.svg_entry_count_max,
            );
        }
        if (self.image_entry_count_max < self.image_request_count_max) {
            return .{
                .budget = .atlas,
                .field = "image_entry_count_max",
                .rule = .below_relationship,
                .value = self.image_entry_count_max,
                .bound = self.image_request_count_max,
            };
        }
        if (self.svg_size < self.svg_icon_size_max + 2) {
            return .{
                .budget = .atlas,
                .field = "svg_size",
                .rule = .below_relationship,
                .value = self.svg_size,
                .bound = self.svg_icon_size_max + 2,
            };
        }
        if (self.upload_bytes_frame_max < self.itemUploadBytesMax()) {
            return .{
                .budget = .atlas,
                .field = "upload_bytes_frame_max",
                .rule = .below_relationship,
                .value = self.upload_bytes_frame_max,
                .bound = self.itemUploadBytesMax(),
            };
        }
        return null;
    }

    /// Staged bytes of the largest glyph or icon, border included. Images have
    /// no budget-wide bound; an image larger than the staging journal fails fast.
    pub fn itemUploadBytesMax(self: *const AtlasLimits) u32 {
        assert(self.svg_icon_size_max <= MAX_SVG_ICON_SIZE);
        const glyph_side: u32 = MAX_GLYPH_SIZE + 2;
        const icon_side: u32 = self.svg_icon_size_max + 2;
        return @max(glyph_side * glyph_side, icon_side * icon_side * 4);
    }

    /// Bytes of the three atlas textures (GPU) or pixel stores (CPU renderer).
    pub fn textureBytes(self: *const AtlasLimits) u64 {
        assert(self.text_size <= MAX_ATLAS_SIZE);
        assert(self.image_size <= MAX_ATLAS_SIZE);
        var bytes: u64 = @as(u64, self.text_size) * self.text_size;
        bytes += @as(u64, self.svg_size) * self.svg_size * 4;
        bytes += @as(u64, self.image_size) * self.image_size * 4;
        return bytes;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
        assert(embedded.check() == null);
    }
};

// Per-window capacities. Every pool is reserved from these
// at initialization; exhausting one panics with the pool's
// name, capacity, requested count, and frame. `ceiling` holds the framework
// maxima `check` enforces.

/// Most elements an app's render may build per frame. The window adds its root,
/// so a layout engine holds at most 65,536 elements, an index range that stays
/// well inside `u32` and keeps the `ceiling` profile's layout reservation at
/// 24 MiB of virtual memory (65,536 × 384 B), resident only as far as frames
/// write. Capacity no longer sets a fixed reservation: every window reserves
/// `build.element_count_frame_max + 1` elements (`LayoutCapacity.fromLimits`).
pub const element_count_frame_ceiling: u32 = 65_535;

/// Deepest box nesting a build may track, the window root included. `Node.depth`
/// is a `u8`, and the layout passes, router, emit and debugger keep their
/// explicit stacks at this ceiling on the call stack (about 1 KiB each).
pub const box_depth_ceiling: u32 = 128;

comptime {
    // `Node.depth` is a `u8`; the window root plus every app element is the
    // 65,536-element layout ceiling the memory budget states.
    assert(box_depth_ceiling <= std.math.maxInt(u8));
    assert(element_count_frame_ceiling + 1 == 65_536);
}

/// The most codepoints one shaped run may hold, on every backend. CoreText
/// shapes at most 2048 UTF-16 units and 1024 glyphs per CTRun, DirectWrite
/// 2048 UTF-16 units, and the core's per-tick text scratch holds the
/// shaped glyphs of one such run with room for the shaper's growth
/// (`textScratchBytes`). A codepoint is at most two UTF-16 units and, in the
/// scripts Gooey shapes, at most one glyph. A longer run fails shaping with
/// `error.TextRunTooLong` before any backend sees it. A platform limit, not an
/// app capacity: measurement and glyph placement split a longer text into runs
/// after a space or line break (`text_system.runLength`), and layout wraps it
/// in batches of this many words, so no text's length reaches it.
pub const run_codepoint_count_max: u32 = 1024;

/// Bytes of one window's per-tick text scratch, from its event budget. Two
/// tenants can hold it at once: the shaped glyphs of the run a frame in
/// flight left there, four times over because the web shaper holds
/// codepoints, byte offsets and a growing glyph list at once; and a file
/// dialog that runs in the next drain, whose platform code allocates its
/// paths and their slices there before `events.Paths.join` copies them once
/// more. The scratch resets only between frames, so it holds both together.
pub fn textScratchBytes(events: *const EventLimits) u32 {
    assert(events.dialog_path_bytes_max > 0);
    assert(events.dialog_path_count_max > 0);
    const run_bytes: u32 = run_codepoint_count_max * @sizeOf(ShapedGlyph);
    const dialog_bytes: u32 = 2 * events.dialog_path_bytes_max +
        @sizeOf([]const u8) * events.dialog_path_count_max;
    const scratch_bytes = 4 * run_bytes + dialog_bytes;
    assert(scratch_bytes > dialog_bytes);
    return scratch_bytes;
}

/// Most handlers one element can register (click, click-outside, key).
pub const handler_count_element_max: u32 = 3;

/// Component recursion is bounded, default 64, ceiling 128.
pub const MAX_COMPONENT_DEPTH: u32 = 128;

/// Build-phase capacities: the element tree one frame may describe.
/// Fragments are numbered in a `u8` after content's zero.
pub const layer_count_ceiling: u32 = std.math.maxInt(u8);

pub const BuildLimits = struct {
    /// Elements (`box`, `text`, `paint`) per frame.
    element_count_frame_max: u32,
    /// Nested `cx.render` calls.
    component_depth_max: u32,
    /// Keyed elements per frame, for duplicate-key detection.
    key_count_frame_max: u32,
    /// Bytes of text and accessibility strings copied per frame.
    text_bytes_frame_max: u32,
    /// Boxes with a `layer` per frame; each opens one fragment
    /// and is one layout floating root.
    layer_count_frame_max: u32,
    /// Deepest box nesting, the window root included, so an app nests
    /// `box_depth_max - 1` levels inside it. Sizes the layout open stack and
    /// the window's open, hover and press paths. The examples peak at 8.
    box_depth_max: u32,

    pub const nano: BuildLimits = .{
        .element_count_frame_max = 512,
        .component_depth_max = 64,
        .key_count_frame_max = 256,
        .text_bytes_frame_max = 16 * 1024,
        .layer_count_frame_max = 8,
        .box_depth_max = 64,
    };
    pub const small: BuildLimits = .{
        .element_count_frame_max = 2_048,
        .component_depth_max = 64,
        .key_count_frame_max = 1_024,
        .text_bytes_frame_max = 64 * 1024,
        .layer_count_frame_max = 16,
        .box_depth_max = 64,
    };
    pub const standard: BuildLimits = .{
        .element_count_frame_max = 4_096,
        .component_depth_max = 64,
        .key_count_frame_max = 4_096,
        .text_bytes_frame_max = 256 * 1024,
        .layer_count_frame_max = 32,
        .box_depth_max = 64,
    };
    pub const large: BuildLimits = .{
        .element_count_frame_max = 16_383,
        .component_depth_max = 64,
        .key_count_frame_max = 16_383,
        .text_bytes_frame_max = 1024 * 1024,
        .layer_count_frame_max = 64,
        .box_depth_max = 64,
    };
    pub const ceiling: BuildLimits = .{
        .element_count_frame_max = element_count_frame_ceiling,
        .component_depth_max = MAX_COMPONENT_DEPTH,
        .key_count_frame_max = element_count_frame_ceiling,
        .text_bytes_frame_max = 4 * 1024 * 1024,
        .layer_count_frame_max = layer_count_ceiling,
        .box_depth_max = box_depth_ceiling,
    };
};

/// Emit-phase capacities: records one frame may hold, per record buffer.
pub const RecordLimits = struct {
    /// Paint records (quads, sprites, meshes, clips) across all fragments.
    paint_record_count_frame_max: u32,
    /// Hit records: interactive or keyed boxes.
    hit_record_count_frame_max: u32,
    /// Handlers bound by `cx.on` during build.
    handler_count_frame_max: u32,

    pub const nano: RecordLimits = .{
        .paint_record_count_frame_max = 4_096,
        .hit_record_count_frame_max = 512,
        .handler_count_frame_max = 512,
    };
    pub const small: RecordLimits = .{
        .paint_record_count_frame_max = 8_192,
        .hit_record_count_frame_max = 2_048,
        .handler_count_frame_max = 2_048,
    };
    pub const standard: RecordLimits = .{
        .paint_record_count_frame_max = 28_672,
        .hit_record_count_frame_max = 4_096,
        .handler_count_frame_max = 4_096,
    };
    pub const large: RecordLimits = .{
        .paint_record_count_frame_max = 65_536,
        .hit_record_count_frame_max = 16_383,
        .handler_count_frame_max = 16_384,
    };
    pub const ceiling: RecordLimits = .{
        .paint_record_count_frame_max = 262_144,
        .hit_record_count_frame_max = element_count_frame_ceiling,
        .handler_count_frame_max = element_count_frame_ceiling * handler_count_element_max,
    };
};

/// Retained-store slabs, one per size class.
pub const RetainedLimits = struct {
    slot_count_64: u32,
    slot_count_256: u32,
    slot_count_1024: u32,
    slot_count_4096: u32,
    /// Untouched frames before a `.frame` entry is released.
    sweep_delay_frames: u32,

    pub const nano: RetainedLimits = .{
        .slot_count_64 = 128,
        .slot_count_256 = 64,
        .slot_count_1024 = 16,
        .slot_count_4096 = 4,
        .sweep_delay_frames = 8,
    };
    pub const small: RetainedLimits = .{
        .slot_count_64 = 512,
        .slot_count_256 = 256,
        .slot_count_1024 = 64,
        .slot_count_4096 = 16,
        .sweep_delay_frames = 8,
    };
    pub const standard: RetainedLimits = .{
        .slot_count_64 = 2_048,
        .slot_count_256 = 1_024,
        .slot_count_1024 = 256,
        .slot_count_4096 = 64,
        .sweep_delay_frames = 8,
    };
    pub const large: RetainedLimits = .{
        .slot_count_64 = 8_192,
        .slot_count_256 = 4_096,
        .slot_count_1024 = 1_024,
        .slot_count_4096 = 256,
        .sweep_delay_frames = 8,
    };
    pub const ceiling: RetainedLimits = .{
        .slot_count_64 = 65_536,
        .slot_count_256 = 16_384,
        .slot_count_1024 = 4_096,
        .slot_count_4096 = 1_024,
        .sweep_delay_frames = 600,
    };
};

/// Free queue slots the largest native host burst needs: a host reads more
/// input only while the queue has room for its whole burst, so every
/// profile's queue holds at least this (`ResourceLimits.check`). Each host
/// declares its own burst and asserts it is at most this: Wayland 256 (one
/// read of libwayland's 4 KiB buffer), fbdev 8 (one evdev packet), Windows 3
/// (one message, plus the resize the next tick pushes).
pub const input_burst_count_max: u32 = 256;

/// Event queue and completion ring.
pub const EventLimits = struct {
    queue_count_max: u32,
    completion_count_max: u32,
    /// Bytes of event text (IME and typed text) in flight. A dialog's paths
    /// and a key event's characters have their own room in the queue.
    text_bytes_max: u32,
    /// Paths one file dialog may select; more fails fast.
    dialog_path_count_max: u32,
    /// Bytes of one dialog's paths, joined (`events.Paths`), and of a save
    /// request's folder and suggested name together. The queue and the
    /// completion ring each reserve this much per dialog slot.
    dialog_path_bytes_max: u32,
    /// File dialogs awaiting their completion at once.
    /// Each completes into the completion ring beside the image worker's one
    /// outstanding decode and the jobs' deliveries, so the ring holds
    /// `dialog_count_max + 1 + job_result_count_max + job_count_max`.
    dialog_count_max: u32,
    /// Background jobs running at once (`Effects.spawn`), each with a runner
    /// and an interrupter task when the app registers `Config.jobs`. One
    /// more spawn is refused with `error.JobBusy`.
    job_count_max: u32,
    /// Bytes of one job's `Input`, copied into its slot at spawn.
    job_input_bytes_max: u32,
    /// Results posted and not yet delivered, across all jobs. A post that
    /// finds every slot held waits on its worker until a drain frees one.
    job_result_count_max: u32,
    /// Bytes of one job's `Result`, copied into a result slot at post.
    job_result_bytes_max: u32,

    pub const nano: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 16,
        .text_bytes_max = 4 * 1024,
        .dialog_path_count_max = 16,
        .dialog_path_bytes_max = 2 * 1024,
        .dialog_count_max = 2,
        .job_count_max = 2,
        .job_input_bytes_max = 256,
        .job_result_count_max = 8,
        .job_result_bytes_max = 1 * 1024,
    };
    pub const small: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 32,
        .text_bytes_max = 8 * 1024,
        .dialog_path_count_max = 32,
        .dialog_path_bytes_max = 4 * 1024,
        .dialog_count_max = 4,
        .job_count_max = 4,
        .job_input_bytes_max = 1 * 1024,
        .job_result_count_max = 16,
        .job_result_bytes_max = 2 * 1024,
    };
    pub const standard: EventLimits = .{
        .queue_count_max = 256,
        .completion_count_max = 64,
        .text_bytes_max = 16 * 1024,
        .dialog_path_count_max = 64,
        .dialog_path_bytes_max = 8 * 1024,
        .dialog_count_max = 8,
        .job_count_max = 8,
        .job_input_bytes_max = 4 * 1024,
        .job_result_count_max = 32,
        .job_result_bytes_max = 4 * 1024,
    };
    pub const large: EventLimits = .{
        .queue_count_max = 512,
        .completion_count_max = 128,
        .text_bytes_max = 64 * 1024,
        .dialog_path_count_max = 256,
        .dialog_path_bytes_max = 32 * 1024,
        .dialog_count_max = 8,
        .job_count_max = 16,
        .job_input_bytes_max = 16 * 1024,
        .job_result_count_max = 64,
        .job_result_bytes_max = 16 * 1024,
    };
    pub const ceiling: EventLimits = .{
        .queue_count_max = 4_096,
        .completion_count_max = 1_024,
        .text_bytes_max = 1024 * 1024,
        .dialog_path_count_max = 1_024,
        .dialog_path_bytes_max = 64 * 1024,
        .dialog_count_max = 64,
        .job_count_max = 64,
        .job_input_bytes_max = 256 * 1024,
        .job_result_count_max = 256,
        .job_result_bytes_max = 64 * 1024,
    };
};

/// One text-engine pool. A count of 0
/// reserves nothing; bytes and undo depth are then unused but still bounded.
pub const TextKindLimits = struct {
    count_max: u32,
    bytes_max: u32,
    undo_depth_max: u32,
};

/// The text system's caches and faces, and the three text-engine pools:
/// single-line inputs, multi-line areas, and code editors. Editors are opt-in:
/// every profile but `ceiling` sets their count to 0, and an app that shows one
/// sets it (the code-editor example sets 1). An area or editor reserves
/// `bytes_max` twice (text and history), so the small profiles keep only a few.
///
/// Cache peaks measured over every example: glyphs 117 at
/// `nano`, 283 at `small` (accessible-form), 222 at `standard`; shaped runs 18
/// / 32 / 256 (data-table and code-editor fill 256); measured widths 19 / 403
/// / 620.
pub const TextLimits = struct {
    /// The font faces the app's text system loads during initialization.
    fonts: FontLimits,
    /// Rendered glyphs the glyph cache holds: one per glyph, size, subpixel
    /// offset and face. A full cache evicts glyphs whose atlas shelf no open
    /// frame used; a frame that draws more distinct glyphs than this fails
    /// fast. The hash table is twice this, a power of two.
    glyph_cache_count_max: u32,
    /// Shaped runs (up to 128 glyphs and 512 bytes each) the shaped-run cache
    /// keeps. It evicts the least recently used, so a miss costs shaping time.
    shaped_run_count_max: u32,
    /// Slots of the width cache `measureText` uses, a power of two of at least
    /// `measure_probe_count + 1`; it evicts the least recently used in a probe
    /// window.
    measure_slot_count_max: u32,
    /// Slots of the size cache `cx.measureText` keeps, a power of two of at
    /// least `measure_probe_count + 1`: one per text, style and width a frame
    /// measures, so a `List` that sizes rows from content re-wraps only rows
    /// that changed. It evicts the least recently used in a probe window, so
    /// a frame that measures more texts than this re-wraps some each frame
    /// (time, not correctness). One slot per distinct text: virtual-list
    /// measures about 1,500 texts a frame but only 8 distinct ones; a chat of
    /// 400 distinct 800-byte messages takes 400, a tenth of `standard`.
    text_size_slot_count_max: u32,
    /// Bytes of IME composition (preedit) one text engine and the platform
    /// window keep. The OS supplies it, so a longer one is cut at a code point
    /// boundary and logged, not a panic. It travels through the event queue's
    /// text, so at most `events.text_bytes_max`.
    preedit_bytes_max: u32,
    input: TextKindLimits,
    area: TextKindLimits,
    editor: TextKindLimits,

    /// The flat cache fields, checked against `ceiling` like other budgets.
    const cache_field_names = .{
        "glyph_cache_count_max",
        "shaped_run_count_max",
        "measure_slot_count_max",
        "text_size_slot_count_max",
        "preedit_bytes_max",
    };

    pub const nano: TextLimits = .{
        .fonts = FontLimits.nano,
        .glyph_cache_count_max = 512,
        .shaped_run_count_max = 64,
        .measure_slot_count_max = 256,
        .text_size_slot_count_max = 256,
        .preedit_bytes_max = 256,
        .input = .{ .count_max = 4, .bytes_max = 1024, .undo_depth_max = 32 },
        .area = .{ .count_max = 0, .bytes_max = 16 * 1024, .undo_depth_max = 32 },
        .editor = .{ .count_max = 0, .bytes_max = 64 * 1024, .undo_depth_max = 64 },
    };
    /// `nano` with a bold face, for board apps with a heading weight.
    pub const embedded: TextLimits = blk: {
        var value = nano;
        value.fonts = FontLimits.embedded;
        break :blk value;
    };
    pub const small: TextLimits = .{
        .fonts = FontLimits.small,
        .glyph_cache_count_max = 1_024,
        .shaped_run_count_max = 128,
        .measure_slot_count_max = 1_024,
        .text_size_slot_count_max = 1_024,
        .preedit_bytes_max = 256,
        .input = .{ .count_max = 16, .bytes_max = 4 * 1024, .undo_depth_max = 64 },
        .area = .{ .count_max = 2, .bytes_max = 64 * 1024, .undo_depth_max = 64 },
        .editor = .{ .count_max = 0, .bytes_max = 256 * 1024, .undo_depth_max = 128 },
    };
    pub const standard: TextLimits = .{
        .fonts = FontLimits.standard,
        .glyph_cache_count_max = 4_096,
        .shaped_run_count_max = 256,
        .measure_slot_count_max = 2_048,
        .text_size_slot_count_max = 4_096,
        .preedit_bytes_max = 1_024,
        .input = .{ .count_max = 64, .bytes_max = 8 * 1024, .undo_depth_max = 64 },
        .area = .{ .count_max = 4, .bytes_max = 128 * 1024, .undo_depth_max = 128 },
        .editor = .{ .count_max = 0, .bytes_max = 1024 * 1024, .undo_depth_max = 256 },
    };
    pub const large: TextLimits = .{
        .fonts = FontLimits.large,
        .glyph_cache_count_max = 8_192,
        .shaped_run_count_max = 512,
        .measure_slot_count_max = 4_096,
        .text_size_slot_count_max = 8_192,
        .preedit_bytes_max = 1_024,
        .input = .{ .count_max = 128, .bytes_max = 8 * 1024, .undo_depth_max = 128 },
        .area = .{ .count_max = 8, .bytes_max = 128 * 1024, .undo_depth_max = 256 },
        .editor = .{ .count_max = 0, .bytes_max = 4 * 1024 * 1024, .undo_depth_max = 512 },
    };
    /// Glyph indexes are `u16` with 0 as "empty", so the cache holds at most
    /// 16,384 and its table 32,768. The preedit ceiling is the Wayland
    /// text-input-v3 limit.
    pub const ceiling: TextLimits = .{
        .fonts = FontLimits.ceiling,
        .glyph_cache_count_max = 16_384,
        .shaped_run_count_max = 1_024,
        .measure_slot_count_max = 16_384,
        .text_size_slot_count_max = 65_536,
        .preedit_bytes_max = 4_000,
        .input = .{ .count_max = 1_024, .bytes_max = 64 * 1024, .undo_depth_max = 1_024 },
        .area = .{ .count_max = 256, .bytes_max = 1024 * 1024, .undo_depth_max = 1_024 },
        .editor = .{ .count_max = 64, .bytes_max = 16 * 1024 * 1024, .undo_depth_max = 4_096 },
    };

    /// The font faces must pass `FontLimits.check`; the cache fields are in
    /// `1..=ceiling` and the width cache is a power of two above its probe
    /// window. Engine counts may be 0; bytes and undo depth must be in
    /// `1..=ceiling`.
    pub fn check(self: *const TextLimits) ?Violation {
        if (self.fonts.check()) |violation| return violation;
        if (self.checkCaches()) |violation| return violation;
        inline for (.{ "input", "area", "editor" }) |kind| {
            const value: *const TextKindLimits = &@field(self, kind);
            const bound: *const TextKindLimits = &@field(ceiling, kind);
            inline for (@typeInfo(TextKindLimits).@"struct".field_names) |field_name| {
                const field_value: u32 = @field(value, field_name);
                const field_bound: u32 = @field(bound, field_name);
                const zero_allowed = comptime std.mem.eql(u8, field_name, "count_max");
                if (field_value == 0 and !zero_allowed) {
                    return .{
                        .budget = .text,
                        .field = kind ++ "." ++ field_name,
                        .rule = .zero,
                        .value = 0,
                        .bound = 1,
                    };
                }
                if (field_value > field_bound) {
                    return .{
                        .budget = .text,
                        .field = kind ++ "." ++ field_name,
                        .rule = .above_ceiling,
                        .value = field_value,
                        .bound = field_bound,
                    };
                }
            }
        }
        return null;
    }

    fn checkCaches(self: *const TextLimits) ?Violation {
        inline for (cache_field_names) |name| {
            const value: u32 = @field(self, name);
            const bound: u32 = @field(ceiling, name);
            if (value == 0) {
                return .{ .budget = .text, .field = name, .rule = .zero, .value = 0, .bound = 1 };
            }
            if (value > bound) {
                return .{
                    .budget = .text,
                    .field = name,
                    .rule = .above_ceiling,
                    .value = value,
                    .bound = bound,
                };
            }
        }
        // Both set-associative caches mask a hash into a power-of-two table
        // and probe a window of `measure_probe_count` slots.
        inline for (.{ "measure_slot_count_max", "text_size_slot_count_max" }) |name| {
            const slots: u32 = @field(self, name);
            if (slots <= measure_probe_count) {
                return .{
                    .budget = .text,
                    .field = name,
                    .rule = .below_relationship,
                    .value = slots,
                    .bound = measure_probe_count + 1,
                };
            }
            if (!std.math.isPowerOfTwo(slots)) {
                return .{
                    .budget = .text,
                    .field = name,
                    .rule = .not_power_of_two,
                    .value = slots,
                    .bound = std.math.ceilPowerOfTwoAssert(u32, slots),
                };
            }
        }
        return null;
    }
};

/// How far the width cache probes from a key's slot before it evicts the
/// least recently used in that window: a fixed bound on each lookup.
pub const measure_probe_count: u32 = 8;

comptime {
    assert(std.math.isPowerOfTwo(TextLimits.ceiling.measure_slot_count_max));
    assert(std.math.isPowerOfTwo(TextLimits.ceiling.text_size_slot_count_max));
    // Glyph indexes plus one, and twice as many hash slots, fit a `u16`.
    assert(2 * TextLimits.ceiling.glyph_cache_count_max < std.math.maxInt(u16));
}

/// Entity pools: every type in `Config.entities` gets one pool of this many.
pub const EntityLimits = struct {
    count_per_type_max: u32,

    pub const nano: EntityLimits = .{ .count_per_type_max = 16 };
    pub const small: EntityLimits = .{ .count_per_type_max = 64 };
    pub const standard: EntityLimits = .{ .count_per_type_max = 256 };
    pub const large: EntityLimits = .{ .count_per_type_max = 1_024 };
    pub const ceiling: EntityLimits = .{ .count_per_type_max = 4_096 };
};

/// Screen-reader capacities: the accessibility nodes each frame records, the
/// tree the platform bridges diff, and the announcements a frame carries.
/// Peaks measured over every example: 24 nodes
/// (accessible-form, `small`), 7 at `nano`, and one announcement per frame.
/// The announcement slots (`polite_pending_max + 1` of `message_bytes_max`)
/// keep per-frame byte budgets: 512 B to 16 KiB.
pub const A11yLimits = struct {
    /// Accessibility nodes per frame (boxes with `a11y`), which sizes both
    /// frames' node pools, the accessibility tree, and each platform bridge's
    /// element slots. Every node is an element, so at most
    /// `build.element_count_frame_max`; tree indexes are `u16`.
    element_count_max: u32,
    /// Polite announcements (`Effects.announce`) pending for the next build.
    /// Pending announcements behave as two live regions:
    /// one assertive slot, which a newer assertive
    /// announcement replaces, and a FIFO of this many polite ones, in which
    /// a newer one past this count replaces the oldest. Replacement is the
    /// defined policy, as a screen reader's own queue behaves, so input that
    /// arrives while a frame is in flight never exhausts the pool.
    announcement_polite_pending_max: u32,
    /// Bytes of one announcement's text, copied out of its handler into a
    /// slot of its own; a longer text is a capacity-planning error and fails
    /// fast. The pool reserves `announcement_polite_pending_max + 1` slots.
    announcement_message_bytes_max: u32,
    /// Bytes of one node's `value` the frame keeps. A longer value, such as
    /// an editor's whole document, is cut to the lines around its
    /// `A11y.selection` (the caret), as native text views expose the text
    /// near the caret rather than the document; the cut comes from
    /// `build.text_bytes_frame_max`, so it is at most that.
    value_bytes_max: u32,

    pub const nano: A11yLimits = .{
        .element_count_max = 128,
        .announcement_polite_pending_max = 3,
        .announcement_message_bytes_max = 128,
        .value_bytes_max = 1024,
    };
    pub const small: A11yLimits = .{
        .element_count_max = 512,
        .announcement_polite_pending_max = 7,
        .announcement_message_bytes_max = 128,
        .value_bytes_max = 4 * 1024,
    };
    pub const standard: A11yLimits = .{
        .element_count_max = 2_048,
        .announcement_polite_pending_max = 15,
        .announcement_message_bytes_max = 128,
        .value_bytes_max = 8 * 1024,
    };
    pub const large: A11yLimits = .{
        .element_count_max = 8_192,
        .announcement_polite_pending_max = 15,
        .announcement_message_bytes_max = 256,
        .value_bytes_max = 16 * 1024,
    };
    pub const ceiling: A11yLimits = .{
        .element_count_max = a11y_element_count_ceiling,
        .announcement_polite_pending_max = 63,
        .announcement_message_bytes_max = 256,
        .value_bytes_max = a11y_value_bytes_ceiling,
    };
};

/// The macOS bridge hands a value to AppKit as one string and asserts it is at
/// most 65,535 bytes; a screen reader reads a few lines around the caret, so
/// 32 KiB is ample and stays under it.
pub const a11y_value_bytes_ceiling: u32 = 32 * 1024;

/// The accessibility tree indexes elements with `u16` and reserves `0xFFFF`
/// as "none"; its fingerprint map holds twice as many buckets, a power of two.
pub const a11y_element_count_ceiling: u32 = 16_384;

comptime {
    assert(a11y_element_count_ceiling < std.math.maxInt(u16));
    assert(2 * a11y_element_count_ceiling <= std.math.maxInt(u16));
    assert(a11y_value_bytes_ceiling <= std.math.maxInt(u16));
    // The tree holds the pending announcements (one assertive, the polite
    // FIFO) plus one live-region change per element, indexed by `u16`; the
    // announcement slots' bytes are a `u32` byte count.
    const pending_ceiling = A11yLimits.ceiling.announcement_polite_pending_max + 1;
    assert(pending_ceiling + a11y_element_count_ceiling < std.math.maxInt(u16));
    assert(@as(u64, pending_ceiling) * A11yLimits.ceiling.announcement_message_bytes_max <=
        std.math.maxInt(u32));
}

/// Every `u32` field of a flat budget must be in `1..=ceiling`.
fn checkCeilings(comptime T: type, comptime budget: Violation.Budget, self: *const T) ?Violation {
    inline for (@typeInfo(T).@"struct".field_names) |field_name| {
        const value: u32 = @field(self, field_name);
        const bound: u32 = @field(T.ceiling, field_name);
        if (value == 0) {
            return .{
                .budget = budget,
                .field = field_name,
                .rule = .zero,
                .value = 0,
                .bound = 1,
            };
        }
        if (value > bound) {
            return .{
                .budget = budget,
                .field = field_name,
                .rule = .above_ceiling,
                .value = value,
                .bound = bound,
            };
        }
    }
    return null;
}

fn relationship(
    comptime budget: Violation.Budget,
    comptime field: []const u8,
    value: u32,
    bound: u32,
) Violation {
    return .{
        .budget = budget,
        .field = field,
        .rule = .above_relationship,
        .value = value,
        .bound = bound,
    };
}

comptime {
    for (ResourceLimits.profile_names) |name| {
        assert(@field(ResourceLimits, name).check() == null);
    }
    assert(BuildLimits.standard.component_depth_max == 64);
    assert(BuildLimits.ceiling.component_depth_max == 128);
}

/// A broken budget rule, precise enough to name in a compile error.
pub const Violation = struct {
    budget: Budget,
    field: []const u8,
    rule: Rule,
    value: u32,
    bound: u32,

    /// The `ResourceLimits` field holding the broken rule.
    pub const Budget = enum {
        paint,
        window,
        frame,
        atlas,
        build,
        records,
        retained,
        events,
        text,
        entities,
        a11y,
    };
    pub const Rule = enum {
        zero,
        above_ceiling,
        below_relationship,
        above_relationship,
        not_multiple,
        /// A count that indexes by mask is not a power of two; `bound` is the
        /// next one up.
        not_power_of_two,
        /// A set names one entry twice (`text.fonts`); `value` is its length.
        duplicate,
        /// A font set lacks `.regular`, which supplies line metrics.
        missing_regular,
    };

    /// Human-readable message. Comptime only: used by `ResourceLimits.validate`.
    pub fn describe(comptime self: Violation) []const u8 {
        return switch (self.rule) {
            .zero => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} must be at least 1, got 0",
                .{ self.budget, self.field },
            ),
            .above_ceiling => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} exceeds the framework ceiling {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .below_relationship => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is below the required minimum {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .above_relationship => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} exceeds {d}, set by a related budget",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .not_multiple => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is not a multiple of {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .not_power_of_two => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} = {d} is not a power of two; use {d}",
                .{ self.budget, self.field, self.value, self.bound },
            ),
            .duplicate => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} lists a font variant twice",
                .{ self.budget, self.field },
            ),
            .missing_regular => std.fmt.comptimePrint(
                "ResourceLimits.{t}.{s} lacks .regular, which supplies line metrics",
                .{ self.budget, self.field },
            ),
        };
    }
};

/// Maximum glyphs in a single shaped run
pub const MAX_GLYPHS_PER_RUN: u32 = 1024;

/// The font faces a text system loads during initialization: one
/// face per entry in `variants`, so `variants.len` is the face count. Nothing is
/// loaded on first use. Text that requests a variant outside the set panics
/// with the variant's name, the loaded set, and this type's name.
///
/// Part of the app's budget as `ResourceLimits.text.fonts`: every
/// `ResourceLimits` profile carries the `FontLimits` profile of the same name,
/// and a budget that needs other faces sets `text.fonts` like any other field.
/// The app forwards it through `FontConfig.limits` to every text system it
/// creates.
///
/// Gooey-owned cost per face, allocated at init: FreeType 16,976 B (mostly a
/// 4,096-entry advance cache), web 1,460 B, DirectWrite 80 B, CoreText 56 B.
/// The platform library keeps its own state per open face; FreeType, HarfBuzz,
/// and Fontconfig used 24-38 KiB of heap per DejaVu face at init, measured
/// with `mallinfo2`.
/// Shaped-run, width, and glyph caches are shared by all faces, not per face.
pub const FontLimits = struct {
    /// Distinct variants; must include `.regular`, which supplies line metrics.
    variants: []const FontVariant,
    /// Variants of the optional second family (`font_mono`).
    /// Empty in every profile, so an app that loads no second family
    /// reserves no faces; when set, it follows the rules of `variants`.
    mono_variants: []const FontVariant = &.{},

    /// The weights Gooey's components and examples use (regular, medium,
    /// semibold, bold) plus italic and bold italic: six faces.
    pub const standard: FontLimits = .{
        .variants = &.{ .regular, .medium, .semibold, .bold, .italic, .bold_italic },
    };

    /// Regular only, for apps whose text never sets a weight or italic.
    pub const nano: FontLimits = .{ .variants = &.{.regular} };

    /// Regular and bold: board apps with one heading weight. Components that
    /// ask for medium or semibold fall back to the nearest of the two.
    pub const embedded: FontLimits = .{ .variants = &.{ .regular, .bold } };

    /// The four upright weights Gooey's components use. accessible-form, the
    /// widest `small` example, requests exactly these.
    pub const small: FontLimits = .{ .variants = &.{ .regular, .medium, .semibold, .bold } };

    /// The same six faces as `standard`: dense apps need more glyphs, not more faces.
    pub const large: FontLimits = standard;

    /// Every weight, upright and italic: the framework ceiling.
    pub const ceiling: FontLimits = .{ .variants = &all_variants };

    const all_variants: [FontVariant.count]FontVariant = blk: {
        var result: [FontVariant.count]FontVariant = undefined;
        for (&result, 0..) |*variant, index| variant.* = @fromBackingInt(@intCast(index));
        break :blk result;
    };

    /// First violated rule, or null when both sets are valid, reported under
    /// `ResourceLimits.text.fonts`. An empty `mono_variants` is valid: it
    /// reserves no second family.
    pub fn check(self: *const FontLimits) ?Violation {
        if (checkVariants("fonts.variants", self.variants, 1)) |violation| return violation;
        return checkVariants("fonts.mono_variants", self.mono_variants, 0);
    }

    /// One family's set: at least `count_min` faces, at most one per variant,
    /// no variant twice, and `.regular` (which supplies line metrics) whenever
    /// the set is not empty.
    fn checkVariants(
        comptime field: []const u8,
        variants: []const FontVariant,
        comptime count_min: u32,
    ) ?Violation {
        const count: u32 = @intCast(@min(variants.len, std.math.maxInt(u32)));
        if (count < count_min) return fontViolation(field, .zero, count, count_min);
        if (count > FontVariant.count) {
            return fontViolation(field, .above_ceiling, count, FontVariant.count);
        }
        if (count == 0) return null;
        if (hasDuplicate(variants)) return fontViolation(field, .duplicate, count, count - 1);
        for (variants) |variant| {
            if (variant == .regular) return null;
        }
        return fontViolation(field, .missing_regular, count, count);
    }

    fn fontViolation(
        comptime field: []const u8,
        rule: Violation.Rule,
        value: u32,
        bound: u32,
    ) Violation {
        assert(rule != .not_multiple);
        assert(rule != .not_power_of_two);
        return .{ .budget = .text, .field = field, .rule = rule, .value = value, .bound = bound };
    }

    fn hasDuplicate(variants: []const FontVariant) bool {
        assert(variants.len <= FontVariant.count);
        var seen: [FontVariant.count]bool = @splat(false);
        for (variants) |variant| {
            if (seen[@backingInt(variant)]) return true;
            seen[@backingInt(variant)] = true;
        }
        return false;
    }

    comptime {
        assert(nano.check() == null);
        assert(small.check() == null);
        assert(standard.check() == null);
        assert(large.check() == null);
        assert(ceiling.check() == null);
    }
};

/// Maximum vertices per individual path. Bounds one path's triangulation
/// scratch so it stays on the stack. Source: triangulator.zig
pub const MAX_PATH_VERTICES: u32 = 512;

/// Maximum triangles per path = MAX_PATH_VERTICES - 2 (simple polygon)
pub const MAX_PATH_TRIANGLES: u32 = MAX_PATH_VERTICES - 2;

/// Maximum indices per path = triangles × 3
pub const MAX_PATH_INDICES: u32 = MAX_PATH_TRIANGLES * 3;

/// Maximum input points for stroke expansion
pub const MAX_STROKE_INPUT: u32 = 512;

/// Maximum output points for stroke expansion.
/// Kept small to avoid stack overflow (ExpandedStroke ~8KB at 1024 points).
/// For UI strokes, 1024 points is plenty (circles flatten to ~64 points).
pub const MAX_STROKE_OUTPUT: u32 = 1024;

/// Number of segments for round caps/joins (affects smoothness)
pub const ROUND_SEGMENTS: u32 = 8;

/// Maximum triangles for direct stroke triangulation
pub const MAX_STROKE_TRIANGLES: u32 = MAX_STROKE_OUTPUT;

/// Maximum indices for stroke triangulation (3 per triangle)
pub const MAX_STROKE_INDICES: u32 = MAX_STROKE_TRIANGLES * 3;

//
// A draw's point count is bounded only by its kind's frame budget
// (`PaintLimits.polyline_point_count_frame_max`, `point_count_frame_max`).

/// Widest polyline, in logical pixels; a sanity bound.
pub const MAX_LINE_WIDTH: f32 = 1000.0;

/// Largest point radius, in logical pixels; a sanity bound.
pub const MAX_POINT_RADIUS: f32 = 1000.0;

comptime {
    std.debug.assert(MAX_GLYPHS_PER_FRAME >= MAX_GLYPHS_PER_RUN);
    std.debug.assert(MAX_CLIP_STACK_DEPTH <= 64); // Reasonable nesting

    std.debug.assert(MAX_PATHS_PER_FRAME >= 1024);

    std.debug.assert(MAX_PATH_TRIANGLES == MAX_PATH_VERTICES - 2);
    std.debug.assert(MAX_PATH_INDICES == MAX_PATH_TRIANGLES * 3);

    std.debug.assert(MAX_STROKE_OUTPUT >= MAX_STROKE_INPUT);
    std.debug.assert(MAX_STROKE_TRIANGLES == MAX_STROKE_OUTPUT);
    std.debug.assert(MAX_STROKE_INDICES == MAX_STROKE_TRIANGLES * 3);
    std.debug.assert(ROUND_SEGMENTS >= 4); // Minimum for visual smoothness
}

test "limit relationships" {
    try std.testing.expectEqual(MAX_PATH_TRIANGLES, MAX_PATH_VERTICES - 2);
    try std.testing.expectEqual(MAX_PATH_INDICES, MAX_PATH_TRIANGLES * 3);
}

test "named profiles are valid and ordered" {
    inline for (ResourceLimits.profile_names) |name| {
        try std.testing.expect(@field(ResourceLimits, name).check() == null);
        try std.testing.expect(@field(FontLimits, name).check() == null);
    }
    const rungs = ResourceLimits.rung_names;
    inline for (rungs[0 .. rungs.len - 1], rungs[1..]) |lower_name, upper_name| {
        const lower = @field(ResourceLimits, lower_name);
        const upper = @field(ResourceLimits, upper_name);
        inline for (.{ "paint", "window", "frame", "atlas" }) |budget| {
            const Budget = @TypeOf(@field(lower, budget));
            inline for (@typeInfo(Budget).@"struct".field_names) |field_name| {
                const lower_value = @field(@field(lower, budget), field_name);
                const upper_value = @field(@field(upper, budget), field_name);
                try std.testing.expect(lower_value <= upper_value);
            }
        }
        const lower_faces = @field(FontLimits, lower_name).variants.len;
        try std.testing.expect(lower_faces <= @field(FontLimits, upper_name).variants.len);
    }
    // Two frames in flight below `standard`, three from it up.
    try std.testing.expectEqual(@as(u32, 2), ResourceLimits.small.frame.in_flight_count);
    try std.testing.expectEqual(@as(u32, 3), ResourceLimits.standard.frame.in_flight_count);
    try std.testing.expectEqual(@as(usize, 1), FontLimits.nano.variants.len);
    try std.testing.expectEqual(@as(usize, 4), FontLimits.small.variants.len);
}

test "the embedded profile fits board panels and stages its largest image in one frame" {
    const embedded = ResourceLimits.embedded;
    try std.testing.expect(embedded.check() == null);
    try std.testing.expect(embedded.window.framebuffer_width_max >= 1024);
    try std.testing.expect(embedded.window.framebuffer_height_max >= 600);
    try std.testing.expect(embedded.window.framebuffer_width_max < 1920);
    const side = embedded.atlas.image_size;
    try std.testing.expect(side * side * 4 <= embedded.atlas.upload_bytes_frame_max);
    try std.testing.expect((side + 1) * (side + 1) * 4 > embedded.atlas.upload_bytes_frame_max);
    try std.testing.expect(side * side * 4 <= embedded.atlas.image_decode_bytes_max);
    try std.testing.expectEqual(@as(usize, 2), embedded.text.fonts.variants.len);
    try std.testing.expectEqual(FontVariant.regular, embedded.text.fonts.variants[0]);
    try std.testing.expect(embedded.window.framebuffer_width_max <
        ResourceLimits.nano.window.framebuffer_width_max);
    try std.testing.expect(embedded.atlas.image_size > ResourceLimits.nano.atlas.image_size);
}

test "check holds every queue to the largest input burst" {
    var limits = ResourceLimits.nano;
    limits.events.queue_count_max = input_burst_count_max;
    try std.testing.expectEqual(@as(?Violation, null), limits.check());
    limits.events.queue_count_max = input_burst_count_max - 1;
    const violation = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.events, violation.budget);
    try std.testing.expectEqualStrings("queue_count_max", violation.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, violation.rule);
    try std.testing.expectEqual(input_burst_count_max - 1, violation.value);
    try std.testing.expectEqual(input_burst_count_max, violation.bound);
}

test "check reports each negative case precisely" {
    var limits = ResourceLimits.standard;
    limits.paint.svg_count_frame_max = 0;
    const zero = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.zero, zero.rule);
    try std.testing.expectEqualStrings("svg_count_frame_max", zero.field);

    limits = ResourceLimits.standard;
    limits.paint.quad_count_frame_max = MAX_QUADS_PER_FRAME + 1;
    const above = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    try std.testing.expectEqual(MAX_QUADS_PER_FRAME, above.bound);

    limits.paint.quad_count_frame_max = MAX_QUADS_PER_FRAME;
    try std.testing.expect(limits.check() == null);

    limits = ResourceLimits.standard;
    limits.paint.glyph_count_frame_max = MAX_GLYPHS_PER_RUN - 1;
    const below = limits.check().?;
    try std.testing.expectEqual(Violation.Rule.below_relationship, below.rule);
    limits.paint.glyph_count_frame_max = MAX_GLYPHS_PER_RUN;
    try std.testing.expect(limits.check() == null);

    limits = ResourceLimits.standard;
    limits.paint.clip_depth_max = MAX_CLIP_STACK_DEPTH + 1;
    try std.testing.expectEqualStrings("clip_depth_max", limits.check().?.field);
    inline for (.{
        "path_vertex_count_frame_max",
        "polyline_point_count_frame_max",
        "point_count_frame_max",
    }) |field| {
        limits = ResourceLimits.standard;
        @field(limits.paint, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.paint, field) = @field(PaintLimits.ceiling, field);
        try std.testing.expect(limits.check() == null);
        @field(limits.paint, field) += 1;
        try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
    }

    limits = ResourceLimits.standard;
    limits.frame.in_flight_count = MIN_FRAMES_IN_FLIGHT - 1;
    try std.testing.expectEqual(Violation.Budget.frame, limits.check().?.budget);
    try std.testing.expectEqual(Violation.Rule.below_relationship, limits.check().?.rule);
    limits.frame.in_flight_count = MIN_FRAMES_IN_FLIGHT;
    try std.testing.expect(limits.check() == null);
    limits.frame.in_flight_count = MAX_FRAMES_IN_FLIGHT;
    try std.testing.expect(limits.check() == null);
    limits.frame.in_flight_count = MAX_FRAMES_IN_FLIGHT + 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("in_flight_count", limits.check().?.field);

    inline for (.{ "framebuffer_width_max", "framebuffer_height_max" }) |field| {
        limits = ResourceLimits.standard;
        @field(limits.window, field) = 0;
        try std.testing.expectEqual(Violation.Budget.window, limits.check().?.budget);
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.window, field) = @field(WindowLimits.ceiling, field);
        try std.testing.expect(limits.check() == null);
        @field(limits.window, field) += 1;
        try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
    }

    // The atlas upload budget must stage the largest glyph or icon in one frame;
    // at `standard` the largest item is a 256² RGBA icon plus its border.
    limits = ResourceLimits.standard;
    const item_bytes_max = limits.atlas.itemUploadBytesMax();
    try std.testing.expectEqual(@as(u32, 258 * 258 * 4), item_bytes_max);
    limits.atlas.upload_bytes_frame_max = item_bytes_max - 1;
    try std.testing.expectEqual(Violation.Budget.atlas, limits.check().?.budget);
    try std.testing.expectEqual(Violation.Rule.below_relationship, limits.check().?.rule);
    limits.atlas.upload_bytes_frame_max = item_bytes_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.upload_bytes_frame_max = MAX_ATLAS_UPLOAD_BYTES_PER_FRAME;
    try std.testing.expect(limits.check() == null);
    limits.atlas.upload_bytes_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);

    // A budget may mix rungs: `.large` with the ceiling quad count and `.standard`
    // mesh geometry. The quad count is exact at the ceiling and one past fails.
    limits = ResourceLimits.large;
    limits.paint.quad_count_frame_max = PaintLimits.ceiling.quad_count_frame_max;
    inline for (.{
        "path_vertex_count_frame_max",
        "polyline_point_count_frame_max",
        "point_count_frame_max",
    }) |field| {
        @field(limits.paint, field) = @field(PaintLimits.standard, field);
    }
    try std.testing.expect(limits.check() == null);
    limits.paint.quad_count_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("quad_count_frame_max", limits.check().?.field);
}

test "check bounds each a11y field by its ceiling and its relationships" {
    inline for (.{
        "element_count_max",
        "announcement_polite_pending_max",
        "announcement_message_bytes_max",
        "value_bytes_max",
    }) |field| {
        var limits = ResourceLimits.ceiling;
        try std.testing.expect(limits.check() == null);
        const field_ceiling = @field(A11yLimits.ceiling, field);
        @field(limits.a11y, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.a11y, field) = field_ceiling + 1;
        const above = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.a11y, above.budget);
        try std.testing.expectEqualStrings(field, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
        try std.testing.expectEqual(field_ceiling, above.bound);
    }

    var limits = ResourceLimits.nano;
    limits.a11y.element_count_max = limits.build.element_count_frame_max;
    try std.testing.expect(limits.check() == null);
    limits.a11y.element_count_max += 1;
    const nodes = limits.check().?;
    try std.testing.expectEqualStrings("element_count_max", nodes.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, nodes.rule);
    try std.testing.expectEqual(limits.build.element_count_frame_max, nodes.bound);

    limits = ResourceLimits.nano;
    limits.a11y.value_bytes_max = limits.build.text_bytes_frame_max;
    try std.testing.expect(limits.check() == null);
    limits.a11y.value_bytes_max += 1;
    const value = limits.check().?;
    try std.testing.expectEqualStrings("value_bytes_max", value.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, value.rule);
    try std.testing.expectEqual(limits.build.text_bytes_frame_max, value.bound);
}

test "check bounds each text cache field by its ceiling and its relationships" {
    inline for (.{
        "glyph_cache_count_max",
        "shaped_run_count_max",
        "measure_slot_count_max",
        "text_size_slot_count_max",
        "preedit_bytes_max",
    }) |field| {
        var limits = ResourceLimits.ceiling;
        try std.testing.expect(limits.check() == null);
        const field_ceiling = @field(TextLimits.ceiling, field);
        @field(limits.text, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.text, field) = field_ceiling + 1;
        const above = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.text, above.budget);
        try std.testing.expectEqualStrings(field, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
        try std.testing.expectEqual(field_ceiling, above.bound);
    }

    var limits = ResourceLimits.nano;
    inline for (.{ "measure_slot_count_max", "text_size_slot_count_max" }) |field| {
        limits = ResourceLimits.nano;
        @field(limits.text, field) = 16;
        try std.testing.expect(limits.check() == null);
        @field(limits.text, field) = measure_probe_count;
        const window = limits.check().?;
        try std.testing.expectEqualStrings(field, window.field);
        try std.testing.expectEqual(Violation.Rule.below_relationship, window.rule);
        try std.testing.expectEqual(measure_probe_count + 1, window.bound);
        // 9 passes the window rule, so only the power-of-two rule can stop it.
        @field(limits.text, field) = measure_probe_count + 1;
        const odd = limits.check().?;
        try std.testing.expectEqualStrings(field, odd.field);
        try std.testing.expectEqual(Violation.Rule.not_power_of_two, odd.rule);
        try std.testing.expectEqual(@as(u32, 16), odd.bound);
    }

    // Every profile's queue holds more text than the preedit ceiling, so the
    // queue shrinks to 2,048 bytes (`nano`'s dialog paths still fit) first.
    limits = ResourceLimits.nano;
    limits.events.text_bytes_max = 2 * 1024;
    limits.text.preedit_bytes_max = limits.events.text_bytes_max;
    try std.testing.expect(limits.check() == null);
    limits.text.preedit_bytes_max += 1;
    const preedit = limits.check().?;
    try std.testing.expectEqualStrings("preedit_bytes_max", preedit.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, preedit.rule);
    try std.testing.expectEqual(limits.events.text_bytes_max, preedit.bound);
}

test "check bounds each atlas cache field by its ceiling and its relationships" {
    inline for (.{
        "svg_entry_count_max",
        "svg_rasterization_count_frame_max",
        "image_entry_count_max",
        "image_path_bytes_max",
    }) |field| {
        var limits = ResourceLimits.ceiling;
        try std.testing.expect(limits.check() == null);
        const field_ceiling = @field(AtlasLimits.ceiling, field);
        @field(limits.atlas, field) = 0;
        try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
        try std.testing.expectEqualStrings(field, limits.check().?.field);
        @field(limits.atlas, field) = field_ceiling + 1;
        const above = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.atlas, above.budget);
        try std.testing.expectEqualStrings(field, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
        try std.testing.expectEqual(field_ceiling, above.bound);
    }

    var limits = ResourceLimits.small;
    const icons_open = atlas_open_frame_count_max * limits.paint.svg_count_frame_max;
    limits.atlas.svg_entry_count_max = icons_open;
    try std.testing.expect(limits.check() == null);
    limits.atlas.svg_entry_count_max -= 1;
    const icons = limits.check().?;
    try std.testing.expectEqualStrings("svg_entry_count_max", icons.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, icons.rule);
    try std.testing.expectEqual(limits.paint.svg_count_frame_max, icons.bound);

    // `small` draws 32 images a frame and requests 8: the frame bound wins.
    limits = ResourceLimits.small;
    limits.atlas.image_entry_count_max = limits.paint.image_count_frame_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.image_entry_count_max -= 1;
    const images = limits.check().?;
    try std.testing.expectEqualStrings("image_entry_count_max", images.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, images.rule);
    try std.testing.expectEqual(limits.paint.image_count_frame_max, images.bound);

    // With few images per frame, the request entries are the bound.
    limits = ResourceLimits.small;
    limits.paint.image_count_frame_max = 1;
    limits.atlas.image_entry_count_max = limits.atlas.image_request_count_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.image_entry_count_max -= 1;
    const requests = limits.check().?;
    try std.testing.expectEqualStrings("image_entry_count_max", requests.field);
    try std.testing.expectEqual(limits.atlas.image_request_count_max, requests.bound);

    // Under the 64-icon work ceiling: 32 entries, so 16 icons per frame.
    limits = ResourceLimits.small;
    limits.paint.svg_count_frame_max = 16;
    limits.atlas.svg_entry_count_max = 32;
    limits.atlas.svg_rasterization_count_frame_max = limits.atlas.svg_entry_count_max;
    try std.testing.expect(limits.check() == null);
    limits.atlas.svg_rasterization_count_frame_max += 1;
    const work = limits.check().?;
    try std.testing.expectEqualStrings("svg_rasterization_count_frame_max", work.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, work.rule);
    try std.testing.expectEqual(limits.atlas.svg_entry_count_max, work.bound);
}

test "check bounds dialog_count_max by its ceiling and the completion ring" {
    var limits = ResourceLimits.ceiling;
    limits.events.dialog_count_max = 0;
    try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
    try std.testing.expectEqualStrings("dialog_count_max", limits.check().?.field);
    limits.events.dialog_count_max = EventLimits.ceiling.dialog_count_max;
    try std.testing.expect(limits.check() == null);
    limits.events.dialog_count_max += 1;
    const above = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.events, above.budget);
    try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    try std.testing.expectEqual(EventLimits.ceiling.dialog_count_max, above.bound);

    // `nano` completes 16 at once: 5 dialogs, the decode, 8 held job
    // results, and the ends of 2 jobs.
    limits = ResourceLimits.nano;
    limits.events.dialog_count_max = 5;
    try std.testing.expect(limits.check() == null);
    limits.events.dialog_count_max += 1;
    const ring = limits.check().?;
    try std.testing.expectEqualStrings("completion_count_max", ring.field);
    try std.testing.expectEqual(Violation.Rule.below_relationship, ring.rule);
    try std.testing.expectEqual(@as(u32, 17), ring.bound);
}

test "check bounds the job fields by their ceilings and the completion ring" {
    inline for (.{
        "job_count_max",
        "job_input_bytes_max",
        "job_result_count_max",
        "job_result_bytes_max",
    }) |name| {
        var limits = ResourceLimits.ceiling;
        @field(limits.events, name) = 0;
        try std.testing.expectEqualStrings(name, limits.check().?.field);
        @field(limits.events, name) = @field(EventLimits.ceiling, name);
        try std.testing.expect(limits.check() == null);
        @field(limits.events, name) += 1;
        const above = limits.check().?;
        try std.testing.expectEqualStrings(name, above.field);
        try std.testing.expectEqual(Violation.Rule.above_ceiling, above.rule);
    }
    var limits = ResourceLimits.nano;
    const room = limits.events.completion_count_max - limits.events.dialog_count_max -
        image_decode_outstanding_max - limits.events.job_count_max;
    limits.events.job_result_count_max = room;
    try std.testing.expect(limits.check() == null);
    limits.events.job_result_count_max += 1;
    const ring = limits.check().?;
    try std.testing.expectEqualStrings("completion_count_max", ring.field);
    try std.testing.expectEqual(limits.events.completion_count_max + 1, ring.bound);
}

test "check bounds box depth and layers by their ceilings and the element count" {
    // The ceilings come from `Node.depth` (`u8`, at most 128 levels) and the
    // `u8` fragment index (255 layers); the relationships hold because every
    // level of nesting and every layer is an element. A 100-element budget
    // puts the relationship below both ceilings, so each rule is seen alone.
    var limits = ResourceLimits.standard;
    limits.build.box_depth_max = 0;
    try std.testing.expectEqual(Violation.Rule.zero, limits.check().?.rule);
    try std.testing.expectEqualStrings("box_depth_max", limits.check().?.field);
    limits.build.box_depth_max = box_depth_ceiling;
    try std.testing.expect(limits.check() == null);
    limits.build.box_depth_max = box_depth_ceiling + 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqual(box_depth_ceiling, limits.check().?.bound);

    limits = ResourceLimits.nano;
    limits.build.element_count_frame_max = 100;
    limits.build.key_count_frame_max = 100;
    limits.records.hit_record_count_frame_max = 100;
    limits.records.handler_count_frame_max = 100;
    limits.a11y.element_count_max = 100;
    limits.build.box_depth_max = 100;
    try std.testing.expect(limits.check() == null);
    limits.build.box_depth_max = 101;
    const depth = limits.check().?;
    try std.testing.expectEqual(Violation.Budget.build, depth.budget);
    try std.testing.expectEqualStrings("box_depth_max", depth.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, depth.rule);
    try std.testing.expectEqual(@as(u32, 100), depth.bound);

    limits.build.box_depth_max = 64;
    limits.build.layer_count_frame_max = 100;
    try std.testing.expect(limits.check() == null);
    limits.build.layer_count_frame_max = 101;
    const layers = limits.check().?;
    try std.testing.expectEqualStrings("layer_count_frame_max", layers.field);
    try std.testing.expectEqual(Violation.Rule.above_relationship, layers.rule);
    try std.testing.expectEqual(@as(u32, 100), layers.bound);

    // Exact is valid, one more is not.
    limits = ResourceLimits.ceiling;
    try std.testing.expect(limits.check() == null);
    try std.testing.expectEqual(element_count_frame_ceiling, limits.build.element_count_frame_max);
    limits.build.element_count_frame_max += 1;
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqualStrings("element_count_frame_max", limits.check().?.field);
}

test "derived budget quantities" {
    // Shadows are packed as quads, so the quad pool holds both budgets.
    const paint = PaintLimits.standard;
    try std.testing.expectEqual(@as(u32, 4_608), packed_frame.quadCapacity(&paint));
    try std.testing.expectEqual(@as(u32, 272), packed_frame.quadCapacity(&PaintLimits.nano));
    const rungs = ResourceLimits.rung_names;
    inline for (rungs[0 .. rungs.len - 1], rungs[1..]) |lower_name, upper_name| {
        const lower_bytes = @field(PaintLimits, lower_name).paintBytes();
        try std.testing.expect(lower_bytes < @field(PaintLimits, upper_name).paintBytes());
    }
    // `nano` worked by hand from the packed frame's layouts: 272 quads and
    // 1,044 sprites at 96 B, 24 meshes at 32 B, 341 edge-mode words at 4 B, an
    // edge table of 1,537 slots at 20 B, and two records frames of 3,072 mesh
    // points at 8 B.
    const nano_bytes = 272 * 96 + 1_044 * 96 + 24 * 32 + 341 * 4 + 1_537 * 20 + 2 * 3_072 * 8;
    try std.testing.expectEqual(@as(u64, nano_bytes), PaintLimits.nano.paintBytes());
    try std.testing.expect(PaintLimits.small.paintBytes() < 1_142 * 1024);
    try std.testing.expect(paint.paintBytes() < 2_894 * 1024);
    try std.testing.expect(PaintLimits.large.paintBytes() < 34 * 1024 * 1024);

    // The text scratch holds a run's glyphs four times over plus one
    // dialog's paths twice and their slices, worked by hand for `nano`.
    const run_bytes = 1_024 * @sizeOf(ShapedGlyph);
    const nano_dialog = 2 * 2_048 + 16 * @sizeOf([]const u8);
    const nano_scratch = textScratchBytes(&EventLimits.nano);
    try std.testing.expectEqual(@as(u32, 4 * run_bytes + nano_dialog), nano_scratch);
    try std.testing.expect(nano_scratch < textScratchBytes(&EventLimits.large));
    try std.testing.expect(textScratchBytes(&EventLimits.ceiling) < 512 * 1024);
}

test "text.fonts reports each broken face set under its own field" {
    var limits = ResourceLimits.nano;
    limits.text.fonts = .{ .variants = &.{.regular}, .mono_variants = &.{ .regular, .bold } };
    try std.testing.expect(limits.check() == null);
    limits.text.fonts = FontLimits.ceiling;
    try std.testing.expect(limits.check() == null);
    try std.testing.expectEqual(@as(usize, FontVariant.count), FontLimits.ceiling.variants.len);

    const Case = struct { fonts: FontLimits, field: []const u8, rule: Violation.Rule };
    const cases = [_]Case{
        .{ .fonts = .{ .variants = &.{} }, .field = "fonts.variants", .rule = .zero },
        .{
            .fonts = .{ .variants = &.{ .regular, .regular } },
            .field = "fonts.variants",
            .rule = .duplicate,
        },
        .{
            .fonts = .{ .variants = &.{.bold} },
            .field = "fonts.variants",
            .rule = .missing_regular,
        },
        .{
            .fonts = .{ .variants = &.{.regular}, .mono_variants = &.{ .regular, .regular } },
            .field = "fonts.mono_variants",
            .rule = .duplicate,
        },
        .{
            .fonts = .{ .variants = &.{.regular}, .mono_variants = &.{.bold} },
            .field = "fonts.mono_variants",
            .rule = .missing_regular,
        },
    };
    inline for (cases) |case| {
        limits.text.fonts = case.fonts;
        const violation = limits.check().?;
        try std.testing.expectEqual(Violation.Budget.text, violation.budget);
        try std.testing.expectEqualStrings(case.field, violation.field);
        try std.testing.expectEqual(case.rule, violation.rule);
    }
    // One face past the ceiling must repeat a variant, so it fails as above
    // the ceiling before the duplicate rule is reached.
    const too_many = FontLimits.all_variants ++ [_]FontVariant{.regular};
    limits.text.fonts = .{ .variants = too_many[0..] };
    try std.testing.expectEqual(Violation.Rule.above_ceiling, limits.check().?.rule);
    try std.testing.expectEqual(@as(u32, FontVariant.count), limits.check().?.bound);
    inline for (ResourceLimits.profile_names) |name| {
        const fonts = @field(ResourceLimits, name).text.fonts;
        try std.testing.expectEqual(@as(usize, 0), fonts.mono_variants.len);
        try std.testing.expectEqual(@field(FontLimits, name).variants.len, fonts.variants.len);
    }
}
