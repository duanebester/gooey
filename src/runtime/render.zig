//! Render Command Execution
//!
//! Converts layout render commands into scene primitives (quads, shadows, text, SVGs, images).

const std = @import("std");

// Core imports
const gooey_mod = @import("../core/gooey.zig");
const scene_mod = @import("../core/scene.zig");
const render_bridge = @import("../core/render_bridge.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const svg_instance_mod = @import("../core/svg_instance.zig");
const image_instance_mod = @import("../core/image_instance.zig");
const image_mod = @import("../image/mod.zig");

const Gooey = gooey_mod.Gooey;
const Hsla = scene_mod.Hsla;
const Quad = scene_mod.Quad;
const Shadow = scene_mod.Shadow;

/// Execute a single render command, adding primitives to the scene
pub fn renderCommand(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    switch (cmd.command_type) {
        .shadow => {
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
        },
        .rectangle => {
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
        },
        .text => {
            const text_data = cmd.data.text;
            const baseline_y = if (gooey_ctx.text_system.getMetrics()) |metrics|
                metrics.calcBaseline(cmd.bounding_box.y, cmd.bounding_box.height)
            else
                cmd.bounding_box.y + cmd.bounding_box.height * 0.75;

            const use_clip = gooey_ctx.scene.hasActiveClip();
            _ = try text_mod.renderText(
                gooey_ctx.scene,
                gooey_ctx.text_system,
                text_data.text,
                cmd.bounding_box.x,
                baseline_y,
                gooey_ctx.scale_factor,
                render_bridge.colorToHsla(text_data.color),
                .{
                    .clipped = use_clip,
                    .decoration = .{
                        .underline = text_data.underline,
                        .strikethrough = text_data.strikethrough,
                    },
                },
            );
        },
        .svg => {
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

            // Get UV coordinates
            const atlas = gooey_ctx.svg_atlas.getAtlas();
            const uv = cached.region.uv(atlas.size);

            // Snap to device pixel grid
            const device_x = b.x * scale_factor;
            const device_y = b.y * scale_factor;
            const snapped_x = @floor(device_x) / scale_factor;
            const snapped_y = @floor(device_y) / scale_factor;

            // Get fill and stroke colors
            const fill_color = if (svg_data.has_fill) render_bridge.colorToHsla(svg_data.color) else Hsla.transparent;
            const stroke_col = if (svg_data.stroke_color) |sc| render_bridge.colorToHsla(sc) else Hsla.transparent;

            const instance = svg_instance_mod.SvgInstance.init(
                snapped_x,
                snapped_y,
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
        },
        .image => {
            const img_data = cmd.data.image;
            const b = cmd.bounding_box;
            const scale_factor = gooey_ctx.scale_factor;

            // Detect if source is a URL or file path
            const is_url = std.mem.startsWith(u8, img_data.source, "http://") or
                std.mem.startsWith(u8, img_data.source, "https://");

            // Create image key
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

            // Check if image is already cached, or try to load it
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

            // Adjust UVs for cropping (cover mode)
            const uv_width = base_uv.u1 - base_uv.u0;
            const uv_height = base_uv.v1 - base_uv.v0;
            const final_uv_left = base_uv.u0 + fit.uv_left * uv_width;
            const final_uv_top = base_uv.v0 + fit.uv_top * uv_height;
            const final_uv_right = base_uv.u0 + fit.uv_right * uv_width;
            const final_uv_bottom = base_uv.v0 + fit.uv_bottom * uv_height;

            // Snap to device pixel grid
            const device_x = (b.x + fit.offset_x) * scale_factor;
            const device_y = (b.y + fit.offset_y) * scale_factor;
            const snapped_x = @floor(device_x) / scale_factor;
            const snapped_y = @floor(device_y) / scale_factor;

            // Create image instance
            var instance = image_instance_mod.ImageInstance.init(
                snapped_x,
                snapped_y,
                fit.width,
                fit.height,
                final_uv_left,
                final_uv_top,
                final_uv_right,
                final_uv_bottom,
            );

            // Apply tint if specified
            if (img_data.tint) |t| {
                instance = instance.withTint(render_bridge.colorToHsla(t));
            }

            // Apply effects
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
        },
        .scissor_start => {
            const scissor = cmd.data.scissor_start;
            try gooey_ctx.scene.pushClip(.{
                .x = scissor.clip_bounds.x,
                .y = scissor.clip_bounds.y,
                .width = scissor.clip_bounds.width,
                .height = scissor.clip_bounds.height,
            });
        },
        .scissor_end => {
            gooey_ctx.scene.popClip();
        },
        else => {},
    }
}
