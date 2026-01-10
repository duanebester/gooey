//! Render Command Execution
//!
//! Converts layout render commands into scene primitives (quads, shadows, text, SVGs, images).
//!
//! ## Design Notes
//!
//! This module translates platform-agnostic layout commands into GPU-ready scene primitives.
//! Each command type maps to specific scene insertion calls (quads, shadows, text runs, etc.).
//!
//! **Performance considerations:**
//! - URL vs path detection is done at render time (could be moved to layout phase in future)
//! - UV calculations are inlined for better cache locality
//! - Pixel snapping is applied for crisp rendering on retina displays

const std = @import("std");

// Core imports
const gooey_mod = @import("../context/gooey.zig");
const scene_mod = @import("../scene/mod.zig");
const render_bridge = @import("../core/render_bridge.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const svg_instance_mod = @import("../scene/svg_instance.zig");
const image_instance_mod = @import("../scene/image_instance.zig");
const image_mod = @import("../image/mod.zig");

const Gooey = gooey_mod.Gooey;
const Hsla = scene_mod.Hsla;
const Quad = scene_mod.Quad;
const Shadow = scene_mod.Shadow;

// =============================================================================
// Main Entry Point
// =============================================================================

/// Execute a single render command, adding primitives to the scene
pub fn renderCommand(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    // Assert bounding box validity
    std.debug.assert(cmd.bounding_box.width >= 0);
    std.debug.assert(cmd.bounding_box.height >= 0);

    switch (cmd.command_type) {
        .shadow => try renderShadow(gooey_ctx, cmd),
        .rectangle => try renderRectangle(gooey_ctx, cmd),
        .border => try renderBorder(gooey_ctx, cmd),
        .text => try renderText(gooey_ctx, cmd),
        .svg => try renderSvg(gooey_ctx, cmd),
        .image => try renderImage(gooey_ctx, cmd),
        .scissor_start => try renderScissorStart(gooey_ctx, cmd),
        .scissor_end => renderScissorEnd(gooey_ctx),
        else => {},
    }
}

// =============================================================================
// Command Renderers
// =============================================================================

/// Render a shadow primitive
fn renderShadow(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const shadow_data = cmd.data.shadow;
    try gooey_ctx.scene.insertShadow(Shadow{
        .content_origin_x = cmd.bounding_box.x,
        .content_origin_y = cmd.bounding_box.y,
        .content_size_width = cmd.bounding_box.width,
        .content_size_height = cmd.bounding_box.height,
        .blur_radius = shadow_data.blur_radius,
        .color = render_bridge.colorToHsla(shadow_data.color),
        .offset_x = shadow_data.offset_x,
        .offset_y = shadow_data.offset_y,
        .corner_radii = .{
            .top_left = shadow_data.corner_radius.top_left,
            .top_right = shadow_data.corner_radius.top_right,
            .bottom_left = shadow_data.corner_radius.bottom_left,
            .bottom_right = shadow_data.corner_radius.bottom_right,
        },
    });
}

/// Render a filled rectangle
fn renderRectangle(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const rect = cmd.data.rectangle;
    const quad = Quad{
        .bounds_origin_x = cmd.bounding_box.x,
        .bounds_origin_y = cmd.bounding_box.y,
        .bounds_size_width = cmd.bounding_box.width,
        .bounds_size_height = cmd.bounding_box.height,
        .background = render_bridge.colorToHsla(rect.background_color),
        .corner_radii = .{
            .top_left = rect.corner_radius.top_left,
            .top_right = rect.corner_radius.top_right,
            .bottom_left = rect.corner_radius.bottom_left,
            .bottom_right = rect.corner_radius.bottom_right,
        },
    };

    if (gooey_ctx.scene.hasActiveClip()) {
        try gooey_ctx.scene.insertQuadClipped(quad);
    } else {
        try gooey_ctx.scene.insertQuad(quad);
    }
}

/// Render a border (SDF-based, supports rounded corners)
fn renderBorder(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const border_data = cmd.data.border;
    const quad = Quad{
        .bounds_origin_x = cmd.bounding_box.x,
        .bounds_origin_y = cmd.bounding_box.y,
        .bounds_size_width = cmd.bounding_box.width,
        .bounds_size_height = cmd.bounding_box.height,
        .background = Hsla.transparent,
        .border_color = render_bridge.colorToHsla(border_data.color),
        .border_widths = .{
            .top = border_data.width.top,
            .right = border_data.width.right,
            .bottom = border_data.width.bottom,
            .left = border_data.width.left,
        },
        .corner_radii = .{
            .top_left = border_data.corner_radius.top_left,
            .top_right = border_data.corner_radius.top_right,
            .bottom_left = border_data.corner_radius.bottom_left,
            .bottom_right = border_data.corner_radius.bottom_right,
        },
    };

    if (gooey_ctx.scene.hasActiveClip()) {
        try gooey_ctx.scene.insertQuadClipped(quad);
    } else {
        try gooey_ctx.scene.insertQuad(quad);
    }
}

/// Render text with baseline calculation
fn renderText(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const text_data = cmd.data.text;
    const baseline_y = if (gooey_ctx.text_system.getMetrics()) |metrics|
        metrics.calcBaseline(cmd.bounding_box.y, cmd.bounding_box.height)
    else
        cmd.bounding_box.y + cmd.bounding_box.height * 0.75;

    const use_clip = gooey_ctx.scene.hasActiveClip();
    var opts = text_mod.RenderTextOptions{
        .clipped = use_clip,
        .decoration = .{
            .underline = text_data.underline,
            .strikethrough = text_data.strikethrough,
        },
        .stats = gooey_ctx.scene.stats,
    };
    _ = try text_mod.renderText(
        gooey_ctx.scene,
        gooey_ctx.text_system,
        text_data.text,
        cmd.bounding_box.x,
        baseline_y,
        gooey_ctx.scale_factor,
        render_bridge.colorToHsla(text_data.color),
        &opts,
    );
}

/// Render SVG with atlas caching
fn renderSvg(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const svg_data = cmd.data.svg;
    const b = cmd.bounding_box;
    const scale_factor = gooey_ctx.scale_factor;

    // Determine stroke width for caching
    const stroke_w: ?f32 = if (svg_data.stroke_color != null)
        svg_data.stroke_width
    else
        null;

    // Get from atlas (rasterizes if not cached)
    const cached = gooey_ctx.svg_atlas.getOrRasterize(
        svg_data.path,
        svg_data.viewbox,
        @max(b.width, b.height),
        svg_data.has_fill,
        stroke_w,
    ) catch return;

    if (cached.region.width == 0) return;

    // Get UV coordinates from atlas
    const atlas = gooey_ctx.svg_atlas.getAtlas();
    const uv = cached.region.uv(atlas.size);

    // Snap to device pixel grid for crisp rendering
    const snapped = snapToPixelGrid(b.x, b.y, scale_factor);

    // Get fill and stroke colors
    const fill_color = if (svg_data.has_fill)
        render_bridge.colorToHsla(svg_data.color)
    else
        Hsla.transparent;
    const stroke_col = if (svg_data.stroke_color) |sc|
        render_bridge.colorToHsla(sc)
    else
        Hsla.transparent;

    const instance = svg_instance_mod.SvgInstance.init(
        snapped.x,
        snapped.y,
        b.width,
        b.height,
        uv.u0,
        uv.v0,
        uv.u1,
        uv.v1,
        fill_color,
        stroke_col,
    );

    try gooey_ctx.scene.insertSvgClipped(instance);
}

/// Render image with atlas caching and fit modes
fn renderImage(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const img_data = cmd.data.image;
    const b = cmd.bounding_box;
    const scale_factor = gooey_ctx.scale_factor;

    // Detect source type
    const is_url = isUrlSource(img_data.source);

    // Create image key based on source type
    const key = if (is_url)
        image_mod.ImageKey.init(
            .{ .url = img_data.source },
            null,
            null,
            scale_factor,
        )
    else
        image_mod.ImageKey.initFromPath(
            img_data.source,
            img_data.width,
            img_data.height,
            scale_factor,
        );

    // Check cache or load synchronously (URLs handled by async loader)
    const cached = gooey_ctx.image_atlas.get(key) orelse blk: {
        if (is_url) return; // URLs handled by async loader

        var decoded = image_mod.loader.loadFromPath(
            gooey_ctx.allocator,
            img_data.source,
        ) catch return;
        defer decoded.deinit();

        break :blk gooey_ctx.image_atlas.cacheImage(key, decoded.toImageData()) catch return;
    };

    if (cached.region.width == 0) return;

    // Get base UV coordinates from atlas region
    const atlas = gooey_ctx.image_atlas.getAtlas();
    const base_uv = cached.region.uv(atlas.size);

    // Calculate fit dimensions and UV adjustments
    const src_w: f32 = @floatFromInt(cached.source_width);
    const src_h: f32 = @floatFromInt(cached.source_height);
    const fit_mode: image_mod.ObjectFit = @enumFromInt(img_data.fit);
    const fit = image_mod.ImageAtlas.calculateFitResult(
        src_w,
        src_h,
        b.width,
        b.height,
        fit_mode,
    );

    // Adjust UVs for cropping (cover mode crops to fit)
    const final_uv = adjustUvForFit(base_uv, fit);

    // Snap to device pixel grid for crisp rendering
    const snapped = snapToPixelGrid(b.x + fit.offset_x, b.y + fit.offset_y, scale_factor);

    // Create image instance with calculated parameters
    var instance = image_instance_mod.ImageInstance.init(
        snapped.x,
        snapped.y,
        fit.width,
        fit.height,
        final_uv.u0,
        final_uv.v0,
        final_uv.u1,
        final_uv.v1,
    );

    // Apply optional effects
    if (img_data.tint) |t| {
        instance = instance.withTint(render_bridge.colorToHsla(t));
    }
    instance = instance.withOpacity(img_data.opacity);
    instance = instance.withGrayscale(img_data.grayscale);

    // Apply corner radius if specified
    if (img_data.corner_radius) |cr| {
        instance = instance.withCornerRadii(
            cr.top_left,
            cr.top_right,
            cr.bottom_right,
            cr.bottom_left,
        );
    }

    try gooey_ctx.scene.insertImageClipped(instance);
}

/// Start a scissor (clip) region
fn renderScissorStart(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const scissor = cmd.data.scissor_start;
    try gooey_ctx.scene.pushClip(.{
        .x = scissor.clip_bounds.x,
        .y = scissor.clip_bounds.y,
        .width = scissor.clip_bounds.width,
        .height = scissor.clip_bounds.height,
    });
}

/// End the current scissor (clip) region
fn renderScissorEnd(gooey_ctx: *Gooey) void {
    gooey_ctx.scene.popClip();
}

// =============================================================================
// Helper Functions
// =============================================================================

/// UV coordinates structure for clarity
const UvRect = struct {
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// Snapped pixel position
const SnappedPosition = struct {
    x: f32,
    y: f32,
};

/// Check if an image source is a URL (http:// or https://)
/// This is called at render time - consider moving to layout phase for better performance
inline fn isUrlSource(source: []const u8) bool {
    return std.mem.startsWith(u8, source, "http://") or
        std.mem.startsWith(u8, source, "https://");
}

/// Snap coordinates to device pixel grid for crisp rendering
/// This prevents sub-pixel blurring on retina displays
inline fn snapToPixelGrid(x: f32, y: f32, scale_factor: f32) SnappedPosition {
    const device_x = x * scale_factor;
    const device_y = y * scale_factor;
    return .{
        .x = @floor(device_x) / scale_factor,
        .y = @floor(device_y) / scale_factor,
    };
}

/// Adjust UV coordinates based on fit result (for cropping in cover mode)
inline fn adjustUvForFit(base_uv: anytype, fit: anytype) UvRect {
    const uv_width = base_uv.u1 - base_uv.u0;
    const uv_height = base_uv.v1 - base_uv.v0;

    return .{
        .u0 = base_uv.u0 + fit.uv_left * uv_width,
        .v0 = base_uv.v0 + fit.uv_top * uv_height,
        .u1 = base_uv.u0 + fit.uv_right * uv_width,
        .v1 = base_uv.v0 + fit.uv_bottom * uv_height,
    };
}
