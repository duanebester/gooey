//! EveRenderer - the EVE backend's contract `Renderer` (contract §9).
//!
//! Translates each packed frame into one BT81x display list, so the chip
//! draws every primitive itself at scan-out time. The list is written over
//! SPI and swapped in at vertical blank; its cost does not depend on panel
//! resolution or on how much of the screen changed.
//!
//! ## Primitive mapping
//!
//! | Packed draw | EVE commands |
//! | --- | --- |
//! | Quad | `RECTS`, `LINE_WIDTH` as the corner radius; borders as below |
//! | Shadow (quad with blur) | Three expanding translucent `RECTS`, an approximation of the blur |
//! | Glyph sprite | One `VERTEX2II` naming an L8 cell in `RAM_G` (`cells.zig`), tinted |
//! | SVG sprite | Stroke and fill coverage as two cells, stroke under fill |
//! | Polyline (`strip_expanded`) | `LINE_STRIP`; EVE rounds joins and caps the GPUs leave butt |
//! | Point cloud | `POINTS` |
//! | Image sprite | `VERTEX2II` of the ARGB4 mirror (`images.zig`), scaled by `BITMAP_TRANSFORM` |
//! | Triangle mesh (paths), colour glyph | Not drawn: fails fast (CLAUDE.md §2) |
//!
//! A quad's border draws as an outer rect in the border colour and an inner
//! rect in the fill. Under a translucent fill the inner rect is first marked
//! in the stencil buffer, so the border never shows through the fill. EVE
//! rects have one radius: mixed corner radii draw with the largest, and an
//! opaque fill redraws its smaller corners.
//!
//! Each draw's clip becomes the scissor, taken over the pixels whose centres
//! lie inside it (contract §9). Cells draw 1:1 at whole pixels (`NEAREST`),
//! so the window's scale is 1 and sprite bounds match their atlas regions.
//! Images draw at whole pixels at any size: 1:1 with `NEAREST`, scaled with
//! `BILINEAR`. Rounded image corners clip through the stencil buffer with
//! the largest radius; a grayscale image fails fast.
//!
//! ## Budgets (CLAUDE.md §2 and §4)
//!
//! - Display list: 2048 commands, the chip's `RAM_DL`. A frame that needs
//!   more fails fast, naming the frame, the draw, and its counts.
//! - `RAM_G` (`limits.zig`): the image mirror (`image_size² × 2`), and glyph
//!   cell pages in the rest below the 64 KiB snapshot scratch; cell
//!   exhaustion fails fast. The EVE host refuses, at compile time, a profile
//!   that leaves too few pages. The host mirrors of the atlases come from the
//!   window's `AtlasLimits`.
//! - SPI per frame: the list, the swap request, new cells, and new image
//!   rows, at most `RAM_DL` plus `AtlasLimits.upload_bytes_frame_max`; more
//!   fails fast. Resending the image mirror after a failed transfer is
//!   exempt, once.
//!
//! ## Resource sketch (CLAUDE.md §7)
//!
//! - Memory: the renderer (about 150 KiB: list 8 KiB, cell table 64 KiB,
//!   staging 64 KiB) lives in the window; the atlas mirrors are reserved at
//!   init (`text_size² + 2 × svg_size² + 2 × image_size²`: 512 KiB at
//!   `.nano`, 672 KiB at `.embedded`).
//! - CPU per frame: one pass over the draws, one hash probe per sprite, a
//!   few words per primitive; no pixel work besides copying new cells.
//! - SPI per frame: at most 8 KiB of list, plus cells on first use. At 30 MHz
//!   a full list takes about 2.2 ms; the swap wait paces frames to the
//!   panel's refresh.

const std = @import("std");
const backend = @import("../../core/backend.zig");
const packed_mod = @import("../../core/packed_frame.zig");
const chip_mod = @import("chip.zig");
const cells_mod = @import("cells.zig");
const display_list = @import("display_list.zig");
const images_mod = @import("images.zig");
const eve_limits = @import("limits.zig");

const assert = std.debug.assert;
const Chip = chip_mod.Chip;
const PackedFrame = packed_mod.PackedFrame;
const DisplayList = display_list.DisplayList;
const Box = display_list.Box;
const ListColor = display_list.Color;
const rect_words = display_list.rect_words_max;

/// Largest panel side: `SCISSOR_SIZE` and `VERTEX2F` reach 2048 px.
pub const panel_side_max: u32 = 2048;
/// Seconds between performance log lines.
const log_period_ns: u64 = 5 * std.time.ns_per_s;
/// Shadow layers, widest and faintest first, stand in for the blur.
const shadow_spreads = [_]f32{ 0.5, 0.3, 0.12 };
/// Each shadow layer's share of the shadow colour's alpha.
const shadow_layer_alpha: f32 = 0.3;

/// Per-frame counts, for the performance log and tests.
pub const FrameStats = struct {
    words: u32 = 0,
    cell_bytes: u32 = 0,
    image_bytes: u64 = 0,
    spi_bytes: u64 = 0,
};

pub const EveRenderer = struct {
    /// `Surface.native`; the platform owns the chip and outlives the renderer.
    chip: ?*Chip = null,
    size_px: backend.SizePx = .{ .width = 0, .height = 0 },
    list: DisplayList = .{},
    cells: cells_mod.CellCache = .{},
    images: images_mod.ImageMirror = .{},
    spi_bytes_frame_max: u64 = 0,
    last_stats: FrameStats = .{},
    /// A failed transfer was logged; later failures are not.
    transfer_failure_logged: bool = false,
    perf: Perf = .{},

    const Self = @This();

    comptime {
        backend.verifyRenderer(Self);
    }

    /// `surface.native` is the platform's `Chip`, whose panel `size_px` is.
    /// Field by field: the renderer is about 150 KiB (CLAUDE.md §13).
    pub fn initInPlace(
        self: *Self,
        surface: *const backend.Surface,
        limits: *const backend.RenderLimits,
    ) !void {
        assert(surface.scale_factor == 1);
        const chip: *Chip = @ptrCast(@alignCast(surface.native.?));
        assert(surface.size_px.width == chip.panel_width);
        assert(surface.size_px.height == chip.panel_height);
        if (chip.panel_width > panel_side_max or chip.panel_height > panel_side_max) {
            return error.EvePanelTooLarge;
        }
        const eve = &eve_limits.EveLimits.bt81x;
        if (eve.check(&limits.atlas)) |reason| {
            std.log.err("eve: ResourceLimits do not fit the chip: {s}", .{reason});
            return error.EveLimitsExceeded;
        }
        const ram = eve.layout(&limits.atlas);
        try self.cells.initInPlace(&limits.atlas, ram.cell_page_count);
        errdefer self.cells.deinit();
        try self.images.initInPlace(limits.atlas.image_size, ram.image_address);
        self.chip = chip;
        self.size_px = surface.size_px;
        self.list.count = 0;
        self.spi_bytes_frame_max = eve.spiBytesFrameMax(&limits.atlas);
        self.last_stats = .{};
        self.transfer_failure_logged = false;
        self.perf = .{};
        assert(self.chip != null);
        assert(self.spi_bytes_frame_max > chip_mod.ram_dl_size);
    }

    pub fn deinit(self: *Self) void {
        if (self.chip == null) return;
        self.images.deinit();
        self.cells.deinit();
        self.chip = null;
        assert(self.chip == null);
    }

    /// Glyph and SVG records land in the host mirrors; cells copy from them
    /// when drawn. Image records convert into the image mirror and reach the
    /// chip with the next frame. There is no colour-glyph drawing yet, so
    /// those records fail fast where an app first loads one.
    pub fn uploadAtlas(
        self: *Self,
        kind: backend.AtlasKind,
        dirty: backend.RectPx,
        pixels: []const u8,
    ) void {
        assert(self.chip != null);
        assert(pixels.len > 0);
        const region = cells_mod.Region{
            .x = dirty.x,
            .y = dirty.y,
            .w = dirty.width,
            .h = dirty.height,
        };
        switch (kind) {
            .glyph => self.cells.uploadGlyphs(region, pixels),
            .svg => self.cells.uploadSvgs(region, pixels),
            .image => self.images.upload(region, pixels),
            .glyph_color => std.debug.panic("EVE renderer: no {t} atlas; the EVE backend " ++
                "draws glyphs, SVG icons, images, quads, polylines, and points", .{kind}),
        }
    }

    /// The panel never changes size; a resize restates it.
    pub fn resize(self: *Self, size_px: backend.SizePx) void {
        assert(self.chip != null);
        assert(std.meta.eql(size_px, self.size_px));
        self.size_px = size_px;
    }

    /// Polylines and point clouds draw; triangle meshes fail fast in `draw`,
    /// which names them, since the flag covers every mesh kind.
    pub fn capabilities(self: *const Self) backend.Capabilities {
        assert(self.chip != null);
        assert(self.size_px.width > 0);
        return .{ .meshes = true };
    }

    /// Wait for the previous list to reach the screen, encode `frame`, send
    /// new cells and the list, and swap it in at the next vertical blank. A
    /// failed transfer skips the frame and is logged once.
    pub fn draw(
        self: *Self,
        frame: *const PackedFrame,
        viewport: backend.Viewport,
        clear: backend.Color,
    ) void {
        const chip = self.chip.?;
        assert(std.meta.eql(viewport.size_px, self.size_px));
        assert(viewport.scale_factor == 1);
        if (viewport.size_px.width == 0) return;
        const started = chip_mod.nowNanoseconds();
        const waited = chip.waitForSwap() catch |err| return self.skipFrame(err);
        _ = chip.takeBytesWritten();
        // A resend after a failed transfer is the one send past the budget.
        const resend = self.images.resend_all;
        const image_bytes = self.images.flush(chip) catch |err| return self.skipFrame(err);
        self.cells.beginFrame();
        self.list.begin(self.size_px.width, self.size_px.height, opaqueRgb(clear));
        for (frame.drawList(), 0..) |*packed_draw, index| {
            self.encodeDraw(frame, packed_draw, @intCast(index)) catch |err| {
                return self.skipFrame(err);
            };
        }
        const encoded = chip_mod.nowNanoseconds();
        self.cells.flush(chip) catch |err| return self.skipFrame(err);
        chip.swapDisplayList(self.list.finish()) catch |err| return self.skipFrame(err);
        const spi_bytes = chip.takeBytesWritten();
        self.checkSpiBudget(frame, spi_bytes - if (resend) image_bytes else 0);
        self.last_stats = .{
            .words = self.list.count,
            .cell_bytes = self.cells.cell_bytes_frame,
            .image_bytes = image_bytes,
            .spi_bytes = spi_bytes,
        };
        const done = chip_mod.nowNanoseconds();
        self.perf.record(&self.last_stats, .{
            .wait_ns = waited,
            .encode_ns = encoded - started - waited,
            .send_ns = done - encoded,
        }, &self.cells);
    }

    fn skipFrame(self: *Self, err: chip_mod.Error) void {
        // Cells and image rows staged or sent may be missing on the chip;
        // upload them again.
        self.cells.forgetAll();
        self.images.forgetAll();
        if (self.transfer_failure_logged) return;
        self.transfer_failure_logged = true;
        std.log.err("eve: SPI transfer failed ({t}); skipping frames until it recovers", .{err});
    }

    fn checkSpiBudget(self: *const Self, frame: *const PackedFrame, spi_bytes: u64) void {
        assert(spi_bytes >= 4);
        if (spi_bytes <= self.spi_bytes_frame_max) return;
        std.debug.panic("EVE renderer: frame {d} sent {d} SPI bytes ({d} of them new glyph " ++
            "cells), past its budget of {d}: RAM_DL plus AtlasLimits.upload_bytes_frame_max. " ++
            "Raise upload_bytes_frame_max or introduce fewer glyphs per frame.", .{
            frame.frame_number,
            spi_bytes,
            self.cells.cell_bytes_frame,
            self.spi_bytes_frame_max,
        });
    }

    // =========================================================================
    // Draws
    // =========================================================================

    fn encodeDraw(
        self: *Self,
        frame: *const PackedFrame,
        packed_draw: *const packed_mod.Draw,
        index: u32,
    ) chip_mod.Error!void {
        assert(packed_draw.count > 0);
        assert(packed_draw.clip < frame.clip_count);
        const clip = scissorOf(frame.clips[packed_draw.clip], self.size_px) orelse return;
        self.list.setClip(clip);
        const context = Context{
            .frame = frame,
            .draw_index = index,
            .pipeline = packed_draw.pipeline,
        };
        switch (packed_draw.pipeline) {
            .quad => for (frame.drawRange(packed_draw, .quad)) |*quad| {
                self.encodeQuad(quad, &context);
            },
            .glyph => for (frame.drawRange(packed_draw, .sprite)) |*sprite| {
                try self.encodeGlyph(sprite, &context);
            },
            .svg => for (frame.drawRange(packed_draw, .sprite)) |*sprite| {
                try self.encodeSvg(sprite, &context);
            },
            .strip_expanded => for (frame.drawRange(packed_draw, .mesh)) |*mesh| {
                self.encodeStrip(mesh, &context);
            },
            .point_instanced => for (frame.drawRange(packed_draw, .mesh)) |*mesh| {
                self.encodePoints(mesh, &context);
            },
            .image => for (frame.drawRange(packed_draw, .sprite)) |*sprite| {
                self.encodeImage(sprite, &context);
            },
            .triangles => std.debug.panic("EVE renderer: frame {d} draws {d} {t} " ++
                "instances, which the EVE backend cannot draw yet (paths)", .{
                frame.frame_number,
                packed_draw.count,
                packed_draw.pipeline,
            }),
        }
    }

    /// Room for `words` more commands, or a fail-fast naming what the frame
    /// asked for.
    fn ensureRoom(self: *const Self, words: u32, context: *const Context) void {
        assert(words > 0);
        if (self.list.room(words)) return;
        const frame = context.frame;
        std.debug.panic("EVE renderer: frame {d} needs more than the {d}-command display " ++
            "list (RAM_DL): {d} used before a {t} instance of draw {d} of {d}, which needs up " ++
            "to {d}. The frame packs {d} quads, {d} sprites, and {d} meshes; draw less " ++
            "per frame.", .{
            frame.frame_number,
            display_list.words_max,
            self.list.count,
            context.pipeline,
            context.draw_index,
            frame.draw_count,
            words,
            frame.quad_count,
            frame.sprite_count,
            frame.mesh_count,
        });
    }

    fn encodeQuad(self: *Self, quad: *const packed_mod.Quad, context: *const Context) void {
        assert(quad.blur >= 0);
        if (quad.blur > 0) return self.encodeShadow(quad, context);
        const box = deviceBox(quad.bounds);
        if (box.w <= 0 or box.h <= 0) return;
        const fill = listColor(quad.fill);
        const border = listColor(quad.border_color);
        const widths = quad.border_widths; // Top, right, bottom, left.
        const has_border = border.alpha > 0 and
            (widths[0] > 0 or widths[1] > 0 or widths[2] > 0 or widths[3] > 0);
        if (fill.alpha == 0 and !has_border) return;
        const corners = quad.corners;
        const radius = @max(@max(@max(corners[0], corners[1]), @max(corners[2], corners[3])), 0);
        if (!has_border) {
            self.ensureRoom(5 * rect_words, context);
            self.list.roundRect(box, radius, fill);
            // Opaque fills redraw their smaller corners over the largest.
            if (fill.alpha == 255) self.patchCorners(box, radius, quad.corners, fill);
            return;
        }
        const inner = Box{
            .x = box.x + @max(widths[3], 0),
            .y = box.y + @max(widths[0], 0),
            .w = box.w - @max(widths[1], 0) - @max(widths[3], 0),
            .h = box.h - @max(widths[0], 0) - @max(widths[2], 0),
        };
        const widest = @max(@max(widths[0], widths[1]), @max(widths[2], widths[3]));
        const inner_radius = @max(radius - widest, 0);
        if (inner.w <= 0 or inner.h <= 0) {
            self.ensureRoom(rect_words, context);
            return self.list.roundRect(box, radius, border);
        }
        if (fill.alpha == 255) {
            self.ensureRoom(2 * rect_words, context);
            self.list.roundRect(box, radius, border);
            return self.list.roundRect(inner, inner_radius, fill);
        }
        self.ensureRoom(4 * rect_words + 10, context);
        const colors = BorderColors{ .fill = fill, .border = border };
        self.borderThroughStencil(box, radius, inner, inner_radius, colors);
    }

    /// A translucent fill under a border: mark the inner area in the stencil
    /// buffer so the border colour lands only on the ring, fill, then unmark.
    fn borderThroughStencil(
        self: *Self,
        box: Box,
        radius: f32,
        inner: Box,
        inner_radius: f32,
        colors: BorderColors,
    ) void {
        assert(inner.w > 0);
        assert(colors.fill.alpha < 255);
        const list = &self.list;
        list.stencilMarkBegin();
        list.roundRect(inner, inner_radius, colors.fill);
        list.stencilOutsideBegin();
        list.roundRect(box, radius, colors.border);
        list.stencilTestEnd();
        if (colors.fill.alpha > 0) list.roundRect(inner, inner_radius, colors.fill);
        list.stencilUnmarkBegin();
        list.roundRect(inner, inner_radius, colors.fill);
        list.stencilUnmarkEnd();
    }

    /// EVE rects have one radius, so `roundRect` drew every corner with the
    /// largest. Each smaller corner is redrawn by a square twice the largest
    /// radius on a side, set in the corner and rounded to the corner's own
    /// radius; its far corners fall inside the shape already drawn. Corners
    /// are top-left, top-right, bottom-right, bottom-left.
    fn patchCorners(self: *Self, box: Box, radius: f32, corners: [4]f32, color: ListColor) void {
        assert(radius >= 0);
        assert(box.w > 0);
        const side = @min(radius, @min(box.w, box.h) / 2) * 2;
        // Below 1 px every corner was already drawn square.
        if (side < 2) return;
        for (corners, 0..) |corner, index| {
            if (corner >= radius) continue;
            const x = if (index == 1 or index == 2) box.x + box.w - side else box.x;
            const y = if (index >= 2) box.y + box.h - side else box.y;
            self.list.roundRect(.{ .x = x, .y = y, .w = side, .h = side }, @max(corner, 0), color);
        }
    }

    fn encodeShadow(self: *Self, quad: *const packed_mod.Quad, context: *const Context) void {
        assert(quad.blur > 0);
        const color = listColor(quad.fill);
        if (color.alpha == 0) return;
        const box = deviceBox(.{
            quad.bounds[0] + quad.offset[0],
            quad.bounds[1] + quad.offset[1],
            quad.bounds[2],
            quad.bounds[3],
        });
        if (box.w <= 0 or box.h <= 0) return;
        self.ensureRoom(shadow_spreads.len * rect_words, context);
        const corners = quad.corners;
        const radius = @max(@max(corners[0], corners[1]), @max(corners[2], corners[3]));
        const layer_alpha = @as(f32, @floatFromInt(color.alpha)) * shadow_layer_alpha;
        const layer = ListColor{ .rgb = color.rgb, .alpha = @intFromFloat(@round(layer_alpha)) };
        for (shadow_spreads) |spread| {
            const grow = quad.blur * spread;
            self.list.roundRect(.{
                .x = box.x - grow,
                .y = box.y - grow,
                .w = box.w + 2 * grow,
                .h = box.h + 2 * grow,
            }, @max(radius, 0) + grow, layer);
        }
    }

    fn encodeGlyph(
        self: *Self,
        sprite: *const packed_mod.Sprite,
        context: *const Context,
    ) chip_mod.Error!void {
        assert(sprite.bounds[2] >= 0);
        assert(self.cells.glyph_size > 0);
        const color = listColor(sprite.tint);
        if (color.alpha == 0) return;
        const region = atlasRegion(sprite.uv, self.cells.glyph_size) orelse return;
        checkSpriteSize(sprite, region, context);
        self.ensureRoom(display_list.cell_words_max, context);
        const cell = try self.cells.lookup(self.chip.?, .glyph, region, context.frame.frame_number);
        const layout = self.cells.pageLayout(cell.page);
        self.list.cell(cell.page, layout, cell.index, pixelOf(sprite.bounds), color);
    }

    /// Stroke first, then fill over it, matching the CPU renderer's
    /// `stroke * (1 - fill)` weighting.
    fn encodeSvg(
        self: *Self,
        sprite: *const packed_mod.Sprite,
        context: *const Context,
    ) chip_mod.Error!void {
        assert(sprite.bounds[2] >= 0);
        assert(self.cells.svg_size > 0);
        const region = atlasRegion(sprite.uv, self.cells.svg_size) orelse return;
        checkSpriteSize(sprite, region, context);
        self.ensureRoom(2 * display_list.cell_words_max, context);
        const number = context.frame.frame_number;
        const at = pixelOf(sprite.bounds);
        const stroke = listColor(sprite.secondary);
        if (stroke.alpha > 0) {
            const cell = try self.cells.lookup(self.chip.?, .svg_stroke, region, number);
            self.list.cell(cell.page, self.cells.pageLayout(cell.page), cell.index, at, stroke);
        }
        const fill = listColor(sprite.tint);
        if (fill.alpha > 0) {
            const cell = try self.cells.lookup(self.chip.?, .svg_fill, region, number);
            self.list.cell(cell.page, self.cells.pageLayout(cell.page), cell.index, at, fill);
        }
    }

    /// `LINE_WIDTH` is the half-width in 1/16 px; at least 1/2 px.
    fn encodeStrip(self: *Self, mesh: *const packed_mod.Mesh, context: *const Context) void {
        assert(mesh.width > 0);
        const points = context.frame.meshPoints(mesh);
        assert(points.len >= 2);
        const color = listColor(mesh.fill);
        if (color.alpha == 0) return;
        self.ensureRoom(display_list.strip_words_max + @as(u32, @intCast(points.len)), context);
        self.list.beginStrip(@max(display_list.roundUnits(mesh.width * 8), 8), color);
        for (points) |point| self.list.vertex(point.x, point.y);
    }

    /// An image sprite from the image mirror, tinted, faded by its opacity,
    /// and clipped to its rounded corners. Grayscale fails fast: EVE has no
    /// per-bitmap colour matrix.
    fn encodeImage(self: *Self, sprite: *const packed_mod.Sprite, context: *const Context) void {
        assert(sprite.bounds[2] >= 0);
        assert(self.images.size > 0);
        if (sprite.grayscale > 0.001) panicGrayscale(sprite, context);
        const tint = sprite.tint;
        const opacity = std.math.clamp(sprite.opacity, 0, 1);
        const color = listColor(.{ tint[0], tint[1], tint[2], tint[3] * opacity });
        if (color.alpha == 0) return;
        const region = atlasRegion(sprite.uv, self.images.size) orelse return;
        const box = deviceBox(sprite.bounds);
        const side_max: f32 = @floatFromInt(panel_side_max - 1);
        const width = std.math.clamp(@round(box.w), 0, side_max);
        const height = std.math.clamp(@round(box.h), 0, side_max);
        if (width < 1 or height < 1) return;
        const draw_image = display_list.ImageDraw{
            .source = self.images.sourceOf(region),
            .stride = self.images.stride(),
            .texels = .{ region.w, region.h },
            .size = .{ @intFromFloat(width), @intFromFloat(height) },
            .at = pixelOf(sprite.bounds),
            .color = color,
        };
        const corners = sprite.corners;
        const radius = @max(@max(corners[0], corners[1]), @max(corners[2], corners[3]));
        if (radius > 0) {
            const words = display_list.image_words_max + display_list.image_rounded_words_extra;
            self.ensureRoom(words, context);
            return self.list.imageRounded(box, radius, &draw_image);
        }
        self.ensureRoom(display_list.image_words_max, context);
        self.list.image(&draw_image);
    }

    /// `POINT_SIZE` is the radius in 1/16 px.
    fn encodePoints(self: *Self, mesh: *const packed_mod.Mesh, context: *const Context) void {
        assert(mesh.width > 0);
        const points = context.frame.meshPoints(mesh);
        assert(points.len >= 1);
        const color = listColor(mesh.fill);
        if (color.alpha == 0) return;
        self.ensureRoom(display_list.strip_words_max + @as(u32, @intCast(points.len)), context);
        self.list.beginPoints(@max(display_list.roundUnits(mesh.width * 16), 1), color);
        for (points) |point| self.list.vertex(point.x, point.y);
    }
};

const BorderColors = struct { fill: ListColor, border: ListColor };

fn panicGrayscale(sprite: *const packed_mod.Sprite, context: *const Context) noreturn {
    assert(sprite.grayscale > 0);
    assert(context.frame.draw_count > 0);
    std.debug.panic("EVE renderer: frame {d} draws an image at grayscale {d:.2} (draw {d}); " ++
        "EVE bitmaps have no colour matrix, so the EVE backend draws images in colour only", .{
        context.frame.frame_number,
        sprite.grayscale,
        context.draw_index,
    });
}

/// What a fail-fast names about the primitive being encoded.
const Context = struct {
    frame: *const PackedFrame,
    draw_index: u32,
    pipeline: packed_mod.Pipeline,
};

// =============================================================================
// Conversions
// =============================================================================

/// The scissor covering the pixels whose centres lie in `clip` (edges
/// included), or null when none do. The unbounded clip is clamped in float
/// first (contract §9).
fn scissorOf(clip: packed_mod.Rect, panel: backend.SizePx) ?display_list.Scissor {
    assert(!std.math.isNan(clip[0]));
    assert(panel.width > 0);
    const width: f32 = @floatFromInt(panel.width);
    const height: f32 = @floatFromInt(panel.height);
    const left = std.math.clamp(@ceil(clip[0] - 0.5), 0, width);
    const top = std.math.clamp(@ceil(clip[1] - 0.5), 0, height);
    // One past the last pixel whose centre is at or before the far edge.
    const right = std.math.clamp(@floor(clip[0] + @max(clip[2], 0) - 0.5) + 1, 0, width);
    const bottom = std.math.clamp(@floor(clip[1] + @max(clip[3], 0) - 0.5) + 1, 0, height);
    if (right <= left or bottom <= top) return null;
    return .{
        @intFromFloat(left),
        @intFromFloat(top),
        @intFromFloat(right - left),
        @intFromFloat(bottom - top),
    };
}

fn deviceBox(rect: packed_mod.Rect) Box {
    assert(!std.math.isNan(rect[0]));
    assert(!std.math.isNan(rect[1]));
    return .{ .x = rect[0], .y = rect[1], .w = @max(rect[2], 0), .h = @max(rect[3], 0) };
}

/// The atlas texels a sprite's UVs cover, or null when none.
fn atlasRegion(uv: [4]f32, atlas_size: u32) ?cells_mod.Region {
    assert(atlas_size > 0);
    assert(!std.math.isNan(uv[0]));
    const size: f32 = @floatFromInt(atlas_size);
    const x0 = std.math.clamp(@round(uv[0] * size), 0, size);
    const y0 = std.math.clamp(@round(uv[1] * size), 0, size);
    const x1 = std.math.clamp(@round(uv[2] * size), 0, size);
    const y1 = std.math.clamp(@round(uv[3] * size), 0, size);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{
        .x = @intFromFloat(x0),
        .y = @intFromFloat(y0),
        .w = @intFromFloat(x1 - x0),
        .h = @intFromFloat(y1 - y0),
    };
}

/// Cells draw 1:1; a sprite drawn larger or smaller than its region would
/// silently come out the wrong size, so it fails fast.
fn checkSpriteSize(
    sprite: *const packed_mod.Sprite,
    region: cells_mod.Region,
    context: *const Context,
) void {
    assert(region.w > 0);
    assert(region.h > 0);
    const width_error = @abs(sprite.bounds[2] - @as(f32, @floatFromInt(region.w)));
    const height_error = @abs(sprite.bounds[3] - @as(f32, @floatFromInt(region.h)));
    if (width_error <= 1 and height_error <= 1) return;
    std.debug.panic("EVE renderer: frame {d} draws a {d}x{d} atlas region into {d:.1}x{d:.1} " ++
        "px ({t}); EVE cells draw only at their own size", .{
        context.frame.frame_number,
        region.w,
        region.h,
        sprite.bounds[2],
        sprite.bounds[3],
        context.pipeline,
    });
}

fn pixelOf(bounds: packed_mod.Rect) [2]i32 {
    assert(!std.math.isNan(bounds[0]));
    assert(!std.math.isNan(bounds[1]));
    return .{
        @intFromFloat(std.math.clamp(@round(bounds[0]), -4096, 4096)),
        @intFromFloat(std.math.clamp(@round(bounds[1]), -4096, 4096)),
    };
}

fn unitByte(value: f32) u8 {
    assert(!std.math.isNan(value));
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 255));
}

fn listColor(rgba: packed_mod.Rgba) ListColor {
    return .{
        .rgb = (@as(u32, unitByte(rgba[0])) << 16) | (@as(u32, unitByte(rgba[1])) << 8) |
            unitByte(rgba[2]),
        .alpha = unitByte(rgba[3]),
    };
}

/// The clear colour over black, as the CPU renderer's opaque framebuffer.
fn opaqueRgb(color: backend.Color) u32 {
    const alpha = std.math.clamp(color.a, 0, 1);
    return listColor(.{ color.r * alpha, color.g * alpha, color.b * alpha, 1 }).rgb;
}

// =============================================================================
// Performance log
// =============================================================================

const Timings = struct {
    wait_ns: u64,
    encode_ns: u64,
    send_ns: u64,
};

/// Totals over `log_period_ns`, logged once per period.
const Perf = struct {
    start_ns: u64 = 0,
    frames: u32 = 0,
    wait_ns: u64 = 0,
    encode_ns: u64 = 0,
    send_ns: u64 = 0,
    words_max: u32 = 0,
    cell_bytes: u64 = 0,

    fn record(
        self: *Perf,
        stats: *const FrameStats,
        timings: Timings,
        cells: *const cells_mod.CellCache,
    ) void {
        assert(stats.words > 0);
        const now = chip_mod.nowNanoseconds();
        if (self.start_ns == 0) self.start_ns = now;
        self.frames += 1;
        self.wait_ns += timings.wait_ns;
        self.encode_ns += timings.encode_ns;
        self.send_ns += timings.send_ns;
        self.words_max = @max(self.words_max, stats.words);
        self.cell_bytes += stats.cell_bytes;
        const elapsed = now - self.start_ns;
        if (elapsed < log_period_ns) return;
        const frames: f64 = @floatFromInt(self.frames);
        std.log.info("eve: {d:.1} fps; per frame: encode {d:.2} ms, send {d:.2} ms, swap wait " ++
            "{d:.2} ms; list max {d}/{d}; {d} KiB new cells; {d}/{d} pages, {d} cells", .{
            frames * std.time.ns_per_s / @as(f64, @floatFromInt(elapsed)),
            msPerFrame(self.encode_ns, frames),
            msPerFrame(self.send_ns, frames),
            msPerFrame(self.wait_ns, frames),
            self.words_max,
            display_list.words_max,
            self.cell_bytes / 1024,
            cells.pagesInUse(),
            cells.page_count,
            cells.entry_count,
        });
        self.* = .{ .start_ns = now };
    }
};

fn msPerFrame(total_ns: u64, frames: f64) f64 {
    assert(frames > 0);
    return @as(f64, @floatFromInt(total_ns)) / frames / std.time.ns_per_ms;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const limits_mod = @import("../../core/limits.zig");

const test_limits = backend.RenderLimits{
    .paint = limits_mod.PaintLimits.nano,
    .window = .{ .framebuffer_width_max = 1024, .framebuffer_height_max = 600 },
    .frame = limits_mod.FrameLimits.nano,
    .atlas = limits_mod.AtlasLimits.nano,
};

const test_viewport = backend.Viewport{
    .size_px = .{ .width = chip_mod.sim_panel_width, .height = chip_mod.sim_panel_height },
    .scale_factor = 1,
};

/// A renderer drawing into a simulated chip that writes no dump.
fn testRenderer(renderer: *EveRenderer, chip: *Chip) !void {
    chip.* = .{};
    try chip.openSimulated(null);
    errdefer chip.close();
    try renderer.initInPlace(&.{
        .native = chip,
        .size_px = test_viewport.size_px,
        .scale_factor = 1,
    }, &test_limits);
}

fn testFrame(frame: *PackedFrame, points: []const packed_mod.MeshPoint) !void {
    try frame.initInPlace(&.{ .paint = test_limits.paint, .paint_record_count_max = 16 });
    frame.reset(1, points);
}

fn appendClip(frame: *PackedFrame, rect: packed_mod.Rect) u32 {
    assert(frame.clip_count < frame.clips.len);
    frame.clips[frame.clip_count] = rect;
    frame.clip_count += 1;
    return frame.clip_count - 1;
}

fn appendDraw(frame: *PackedFrame, pipeline: packed_mod.Pipeline, first: u32, clip: u32) void {
    assert(frame.draw_count < frame.draws.len);
    assert(clip == packed_mod.clip_none or clip < frame.clip_count);
    frame.draws[frame.draw_count] = .{
        .pipeline = pipeline,
        .clip = clip,
        .first = first,
        .count = 1,
    };
    frame.draw_count += 1;
}

/// The words of the list the renderer last swapped in.
fn testWords(renderer: *const EveRenderer) []const u32 {
    return renderer.list.words[0..renderer.list.count];
}

fn containsSequence(words: []const u32, sequence: []const u32) bool {
    assert(sequence.len > 0);
    if (words.len < sequence.len) return false;
    for (0..words.len - sequence.len + 1) |start| {
        if (std.mem.eql(u32, words[start..][0..sequence.len], sequence)) return true;
    }
    return false;
}

/// `VERTEX2F` at `VERTEX_FORMAT(3)`: 1/8 px.
fn testVertex(x: f32, y: f32) u32 {
    const fx: u32 = @intFromFloat(x * 8);
    const fy: u32 = @intFromFloat(y * 8);
    return (1 << 30) | ((fx & 0x7FFF) << 15) | (fy & 0x7FFF);
}

test "a clipped polyline is one LINE_STRIP inside the clip's pixel-centre scissor" {
    // Goal: the ECG path. One vertex per point, in order and at 1/8 px, after
    // a scissor taken over the pixels whose centres lie in the clip (contract
    // §9). The clip's edges sit inside pixels, so a scissor grown outward to
    // whole pixels differs: x 10.6..40.4 holds the centres of columns 11 to
    // 39 (29 columns, not 31 from 10), y 20.6..29.4 rows 21 to 28 (8, not 10).
    const points = [_]packed_mod.MeshPoint{
        .{ .x = 12, .y = 22 }, .{ .x = 20.5, .y = 25.125 }, .{ .x = 38, .y = 28 },
    };
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &points);
    defer frame.deinit();
    const clip = appendClip(&frame, .{ 10.6, 20.6, 29.8, 8.8 });
    frame.counts[@backingInt(packed_mod.Pool.polylines)] += 1;
    frame.meshes[0] = .{
        .fill = .{ 0, 1, 0, 1 },
        .first = 0,
        .count = 3,
        .width = 3,
        .edge_first = 0,
    };
    frame.mesh_count = 1;
    appendDraw(&frame, .strip_expanded, 0, clip);

    var chip: Chip = undefined;
    var renderer: EveRenderer = undefined;
    try testRenderer(&renderer, &chip);
    defer chip.close();
    defer renderer.deinit();
    renderer.draw(&frame, test_viewport, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    const words = testWords(&renderer);
    const scissor = [_]u32{ (27 << 24) | (11 << 11) | 21, (28 << 24) | (29 << 12) | 8 };
    try testing.expect(containsSequence(words, &scissor));
    const strip = [_]u32{
        (31 << 24) | 4, // BEGIN(LINE_STRIP)
        testVertex(12, 22),
        testVertex(20.5, 25.125),
        testVertex(38, 28),
    };
    try testing.expect(containsSequence(words, &strip));
    // LINE_WIDTH is the half width in 1/16 px: 1.5 px.
    try testing.expect(std.mem.indexOfScalar(u32, words, (14 << 24) | 24) != null);
    try testing.expectEqual(@as(u32, 0), words[words.len - 1]); // DISPLAY
}

test "a translucent fill under a border marks, draws outside, and unmarks the stencil" {
    // Goal: the border never shows through a translucent fill, and the
    // stencil is clean for the next quad. Methodology: find the stencil and
    // colour-mask commands in order; an opaque fill must use none of them.
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &.{});
    defer frame.deinit();
    frame.quads[0] = .{
        .bounds = .{ 100, 100, 60, 40 },
        .fill = .{ 1, 0, 0, 0.5 },
        .border_color = .{ 0, 0, 1, 1 },
        .corners = @splat(6),
        .border_widths = @splat(3),
        .blur = 0,
        .offset = .{ 0, 0 },
    };
    frame.quads[1] = frame.quads[0];
    frame.quads[1].bounds = .{ 300, 100, 60, 40 };
    frame.quads[1].fill = .{ 1, 0, 0, 1 };
    frame.counts[@backingInt(packed_mod.Pool.quads)] += 2;
    frame.quad_count = 2;
    appendDraw(&frame, .quad, 0, packed_mod.clip_none);

    var chip: Chip = undefined;
    var renderer: EveRenderer = undefined;
    try testRenderer(&renderer, &chip);
    defer chip.close();
    defer renderer.deinit();
    renderer.draw(&frame, test_viewport, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    const words = testWords(&renderer);
    const mask_off: u32 = 32 << 24;
    const mark = [_]u32{
        mask_off,
        (10 << 24) | (7 << 16) | (1 << 8) | 0xFF, // STENCIL_FUNC(ALWAYS, 1, 255)
        (12 << 24) | (2 << 3) | 2, // STENCIL_OP(REPLACE, REPLACE)
    };
    const outside = [_]u32{ (32 << 24) | 0xF, (10 << 24) | (6 << 16) | (1 << 8) | 0xFF };
    const marked = std.mem.indexOf(u32, words, &mark).?;
    const drawn = std.mem.indexOf(u32, words, &outside).?;
    try testing.expect(marked < drawn);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u32, words, &.{mask_off}));

    // The opaque quad alone: border rect, then fill rect, no stencil.
    frame.quads[0] = frame.quads[1];
    renderer.draw(&frame, test_viewport, .{ .r = 1, .g = 1, .b = 1, .a = 1 });
    try testing.expectEqual(@as(usize, 0), std.mem.count(u32, testWords(&renderer), &.{mask_off}));
}

test "an image draws from the image mirror, scaled by the transform" {
    // Goal: the image path end to end on the simulated chip. A 4x2 upload at
    // (8, 4) of the 256² nano image atlas reaches RAM_G as ARGB4 at the
    // mirror's address; a sprite drawing it 8x2 (twice as wide) names handle
    // 14, the ARGB4 format and the region's source, filters bilinearly, and
    // sets BITMAP_TRANSFORM_A to 128 (half a texel per pixel) and leaves _E
    // at 1:1. Methodology: compare against words built from the BT81x guide,
    // independently of the encoder's helpers.
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &.{});
    defer frame.deinit();
    const size: f32 = @floatFromInt(test_limits.atlas.image_size);
    frame.sprites[0] = .{
        .bounds = .{ 100, 50, 8, 2 },
        .uv = .{ 8 / size, 4 / size, 12 / size, 6 / size },
        .tint = .{ 1, 1, 1, 1 },
        .secondary = .{ 0, 0, 0, 0 },
        .corners = @splat(0),
        .grayscale = 0,
        .opacity = 1,
    };
    frame.sprite_count = 1;
    frame.counts[@backingInt(packed_mod.Pool.images)] += 1;
    appendDraw(&frame, .image, 0, packed_mod.clip_none);

    var chip: Chip = undefined;
    var renderer: EveRenderer = undefined;
    try testRenderer(&renderer, &chip);
    defer chip.close();
    defer renderer.deinit();
    var red_opaque: [8][4]u8 = @splat(.{ 255, 0, 0, 255 });
    const pixels = std.mem.sliceAsBytes(&red_opaque);
    renderer.uploadAtlas(.image, .{ .x = 8, .y = 4, .width = 4, .height = 2 }, pixels);
    renderer.draw(&frame, test_viewport, .{ .r = 0, .g = 0, .b = 0, .a = 1 });

    const ram = eve_limits.EveLimits.bt81x.layout(&test_limits.atlas);
    const stride: u32 = test_limits.atlas.image_size * 2;
    const source = ram.image_address + 4 * stride + 8 * 2;
    const texel = std.mem.readInt(u16, chip.sim_memory[source..][0..2], .little);
    try testing.expectEqual(@as(u16, 0xFF00), texel);
    const words = testWords(&renderer);
    const setup = [_]u32{
        (5 << 24) | 14, // BITMAP_HANDLE(14)
        (1 << 24) | source, // BITMAP_SOURCE
        (7 << 24) | (6 << 19) | ((stride & 1023) << 9) | 2, // BITMAP_LAYOUT(ARGB4, stride, 2)
        (40 << 24) | ((stride >> 10) << 2), // BITMAP_LAYOUT_H
        (8 << 24) | (1 << 20) | (8 << 9) | 2, // BITMAP_SIZE(BILINEAR, BORDER, 8, 2)
        (41 << 24), // BITMAP_SIZE_H
        (21 << 24) | 128, // BITMAP_TRANSFORM_A: 0.5 texel per pixel
    };
    try testing.expect(containsSequence(words, &setup));
    try testing.expect(std.mem.indexOfScalar(u32, words, (25 << 24) | 256) == null);
    const vertex = (2 << 30) | (100 << 21) | (50 << 12) | (14 << 7); // VERTEX2II(100, 50, 14, 0)
    try testing.expect(std.mem.indexOfScalar(u32, words, vertex) != null);
}

test "a 1:1 image samples the nearest texel; a rounded, faded one draws inside a stencil mark" {
    // Goal: the two other image paths. A sprite drawn at its region's size
    // must not filter (a bilinear 1:1 draw blurs by half a texel) or emit a
    // transform; one with corners and opacity 0.5 must draw at COLOR_A 128
    // between STENCIL_FUNC(EQUAL, 1) and the unmark. Methodology: two image
    // draws of a 4x2 region, the first 4x2 at (10, 10), the second 4x2 at
    // (40, 10) with radius 1 and opacity 0.5; words built from the guide.
    var frame: PackedFrame = undefined;
    try testFrame(&frame, &.{});
    defer frame.deinit();
    const size: f32 = @floatFromInt(test_limits.atlas.image_size);
    const sprite = packed_mod.Sprite{
        .bounds = .{ 10, 10, 4, 2 },
        .uv = .{ 8 / size, 4 / size, 12 / size, 6 / size },
        .tint = .{ 1, 1, 1, 1 },
        .secondary = .{ 0, 0, 0, 0 },
        .corners = @splat(0),
        .grayscale = 0,
        .opacity = 1,
    };
    frame.sprites[0] = sprite;
    frame.sprites[1] = sprite;
    frame.sprites[1].bounds = .{ 40, 10, 4, 2 };
    frame.sprites[1].corners = @splat(1);
    frame.sprites[1].opacity = 0.5;
    frame.sprite_count = 2;
    frame.counts[@backingInt(packed_mod.Pool.images)] += 2;
    appendDraw(&frame, .image, 0, packed_mod.clip_none);
    appendDraw(&frame, .image, 1, packed_mod.clip_none);

    var chip: Chip = undefined;
    var renderer: EveRenderer = undefined;
    try testRenderer(&renderer, &chip);
    defer chip.close();
    defer renderer.deinit();
    var white: [8][4]u8 = @splat(.{ 255, 255, 255, 255 });
    const pixels = std.mem.sliceAsBytes(&white);
    renderer.uploadAtlas(.image, .{ .x = 8, .y = 4, .width = 4, .height = 2 }, pixels);
    renderer.draw(&frame, test_viewport, .{ .r = 0, .g = 0, .b = 0, .a = 1 });
    const words = testWords(&renderer);

    const nearest = (8 << 24) | (4 << 9) | 2; // BITMAP_SIZE(NEAREST, BORDER, 4, 2)
    try testing.expectEqual(@as(usize, 2), std.mem.count(u32, words, &.{nearest}));
    for (words) |word| try testing.expect(word >> 24 != 21 and word >> 24 != 25);
    const inside = [_]u32{
        (32 << 24) | 0xF, // COLOR_MASK(1, 1, 1, 1)
        (10 << 24) | (5 << 16) | (1 << 8) | 0xFF, // STENCIL_FUNC(EQUAL, 1, 255)
    };
    // The faded alpha is set with the mask rect and stays for the image.
    const faded = std.mem.indexOfScalar(u32, words, (16 << 24) | 128).?;
    const masked = std.mem.indexOfPos(u32, words, faded, &inside).?;
    const second = (2 << 30) | (40 << 21) | (10 << 12) | (14 << 7); // VERTEX2II(40, 10, 14, 0)
    const drawn = std.mem.indexOfScalarPos(u32, words, masked, second).?;
    const unmark = std.mem.indexOfScalarPos(u32, words, drawn, (32 << 24)).?;
    try testing.expect(unmark > drawn);
    try testing.expect(std.mem.indexOfScalar(u32, words[faded..drawn], (16 << 24) | 255) == null);
}
