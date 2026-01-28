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
const builtin = @import("builtin");

// Core imports
const gooey_mod = @import("../context/gooey.zig");
const scene_mod = @import("../scene/mod.zig");
const render_bridge = @import("../scene/render_bridge.zig");
const layout_mod = @import("../layout/layout.zig");
const text_mod = @import("../text/mod.zig");
const svg_instance_mod = @import("../scene/svg_instance.zig");
const image_instance_mod = @import("../scene/image_instance.zig");
const image_mod = @import("../image/mod.zig");

const Gooey = gooey_mod.Gooey;
const Hsla = scene_mod.Hsla;
const Quad = scene_mod.Quad;
const Shadow = scene_mod.Shadow;
const Color = @import("../ui/styles.zig").Color;

// WASM async image loading
const is_wasm = builtin.cpu.arch == .wasm32;
const wasm_imports = if (is_wasm) @import("../platform/web/imports.zig") else struct {
    pub fn err(comptime _: []const u8, _: anytype) void {}
    pub fn log(comptime _: []const u8, _: anytype) void {}
};
const wasm_loader = if (is_wasm)
    @import("../platform/web/image_loader.zig")
else
    struct {
        pub const DecodedImage = struct {
            width: u32,
            height: u32,
            pixels: []u8,
            owned: bool,
            pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        };
        pub fn loadFromUrlAsync(_: []const u8, _: anytype) ?u32 {
            return null;
        }
        pub fn init(_: std.mem.Allocator) void {}
    };

// =============================================================================
// WASM Image Loading State
// =============================================================================

/// Loading status for async image loads
const LoadStatus = enum {
    not_started,
    loading,
    cached,
    failed,
};

/// Pending load entry (keyed by ImageKey to avoid hash collisions)
const PendingLoad = struct {
    request_id: u32,
    status: LoadStatus,
};

/// Maximum concurrent image loads (per CLAUDE.md: put a limit on everything)
const MAX_PENDING_LOADS: usize = 64;

/// Global state for WASM image loading (WASM is single-threaded, so this is safe)
/// Uses ImageKey as map key to avoid hash collisions when same source is requested
/// with different dimensions/scale factors
var g_pending_loads: std.AutoHashMap(image_mod.ImageKey, PendingLoad) = undefined;
var g_gooey_ctx: ?*Gooey = null;
var g_allocator: ?std.mem.Allocator = null;
var g_wasm_loader_initialized: bool = false;

/// Initialize WASM image loading (called once at startup)
pub fn initWasmImageLoader(allocator: std.mem.Allocator) void {
    // Assert allocator is valid (has non-null vtable)
    std.debug.assert(@intFromPtr(allocator.vtable) != 0);

    if (g_wasm_loader_initialized) return;

    if (is_wasm) {
        wasm_loader.init(allocator);
    }
    g_pending_loads = std.AutoHashMap(image_mod.ImageKey, PendingLoad).init(allocator);
    g_allocator = allocator;
    g_wasm_loader_initialized = true;

    // Assert initialization completed successfully
    std.debug.assert(g_wasm_loader_initialized);
}

/// Deinitialize WASM image loader (for graceful shutdown)
pub fn deinitWasmImageLoader() void {
    if (!g_wasm_loader_initialized) return;

    // Clear all pending loads
    g_pending_loads.deinit();
    g_gooey_ctx = null;
    g_allocator = null;
    g_wasm_loader_initialized = false;

    // Assert cleanup completed
    std.debug.assert(!g_wasm_loader_initialized);
    std.debug.assert(g_gooey_ctx == null);
}

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
    const font_size_f: f32 = @floatFromInt(text_data.font_size);

    // Calculate baseline using requested font size
    const baseline_y = if (gooey_ctx.text_system.getMetrics()) |metrics| blk: {
        const scale = font_size_f / metrics.point_size;
        const scaled_ascender = metrics.ascender * scale;
        break :blk cmd.bounding_box.y + scaled_ascender;
    } else cmd.bounding_box.y + cmd.bounding_box.height * 0.75;

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
        font_size_f,
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
    const cached = gooey_ctx.svg_atlas.*.getOrRasterize(
        svg_data.path,
        svg_data.viewbox,
        @max(b.width, b.height),
        svg_data.has_fill,
        stroke_w,
    ) catch return;

    if (cached.region.width == 0) return;

    // Use cached atlas size for thread-safe UV calculation
    // (atlas may grow between caching and UV calculation in multi-window scenarios)
    const uv = cached.uv();

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
/// On WASM, handles async loading transparently - shows placeholder while loading
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

    // On WASM, handle async loading for non-URL sources (relative paths)
    if (is_wasm and !is_url) {
        // Check if already cached
        if (gooey_ctx.image_atlas.*.get(key) == null) {
            // Not cached - check/start async load
            const status = ensureWasmImageLoading(img_data.source, key, gooey_ctx);

            switch (status) {
                .loading, .not_started => {
                    // Show placeholder while loading
                    try renderImagePlaceholder(gooey_ctx, cmd);
                    return;
                },
                .failed => {
                    // Show error placeholder
                    try renderImageError(gooey_ctx, cmd);
                    return;
                },
                .cached => {}, // Continue to normal rendering
            }
        }
    }

    // Check cache or load synchronously (URLs handled by async loader)
    const cached = gooey_ctx.image_atlas.*.get(key) orelse blk: {
        if (is_url) return; // URLs handled by async loader
        if (is_wasm) return; // WASM uses async loading above

        var decoded = image_mod.loader.loadFromPath(
            gooey_ctx.allocator,
            img_data.source,
        ) catch return;
        defer decoded.deinit();

        break :blk gooey_ctx.image_atlas.*.cacheImage(key, decoded.toImageData()) catch return;
    };

    if (cached.region.width == 0) return;

    // Use cached atlas size for thread-safe UV calculation
    // (atlas may grow between caching and UV calculation in multi-window scenarios)
    const base_uv = cached.uv();

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

/// Render a placeholder box while image is loading
fn renderImagePlaceholder(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const img_data = cmd.data.image;
    const b = cmd.bounding_box;

    // Use provided placeholder color or default gray
    const placeholder_color = img_data.placeholder_color orelse Color.fromHex("#e0e0e0");

    const quad = Quad{
        .bounds_origin_x = b.x,
        .bounds_origin_y = b.y,
        .bounds_size_width = b.width,
        .bounds_size_height = b.height,
        .background = render_bridge.colorToHsla(placeholder_color),
        .corner_radii = if (img_data.corner_radius) |cr| .{
            .top_left = cr.top_left,
            .top_right = cr.top_right,
            .bottom_left = cr.bottom_left,
            .bottom_right = cr.bottom_right,
        } else .{},
    };

    if (gooey_ctx.scene.hasActiveClip()) {
        try gooey_ctx.scene.insertQuadClipped(quad);
    } else {
        try gooey_ctx.scene.insertQuad(quad);
    }
}

/// Render an error indicator when image fails to load
fn renderImageError(gooey_ctx: *Gooey, cmd: layout_mod.RenderCommand) !void {
    const img_data = cmd.data.image;
    const b = cmd.bounding_box;

    // Show a subtle red-tinted placeholder for errors
    const error_color = Color.fromHex("#ffcccc");

    const quad = Quad{
        .bounds_origin_x = b.x,
        .bounds_origin_y = b.y,
        .bounds_size_width = b.width,
        .bounds_size_height = b.height,
        .background = render_bridge.colorToHsla(error_color),
        // Respect corner radius for visual consistency with placeholder
        .corner_radii = if (img_data.corner_radius) |cr| .{
            .top_left = cr.top_left,
            .top_right = cr.top_right,
            .bottom_left = cr.bottom_left,
            .bottom_right = cr.bottom_right,
        } else .{},
    };

    if (gooey_ctx.scene.hasActiveClip()) {
        try gooey_ctx.scene.insertQuadClipped(quad);
    } else {
        try gooey_ctx.scene.insertQuad(quad);
    }
}

/// Maximum source path length (per CLAUDE.md: put a limit on everything)
const MAX_SOURCE_PATH_LEN: usize = 4096;

/// Ensure an image is loading on WASM (starts load if not already in progress)
fn ensureWasmImageLoading(source: []const u8, key: image_mod.ImageKey, gooey_ctx: *Gooey) LoadStatus {
    // Assert source validity (per CLAUDE.md: minimum 2 assertions per function)
    std.debug.assert(source.len > 0); // Source must not be empty
    std.debug.assert(source.len < MAX_SOURCE_PATH_LEN); // Source path must be reasonable length

    if (!is_wasm) return .failed;

    // Initialize if needed
    if (!g_wasm_loader_initialized) {
        initWasmImageLoader(gooey_ctx.allocator);
    }

    // Check if already cached in atlas
    if (gooey_ctx.image_atlas.*.contains(key)) {
        // Clean up any stale pending entry
        _ = g_pending_loads.remove(key);
        return .cached;
    }

    // Check pending loads (use full ImageKey to avoid hash collisions)
    if (g_pending_loads.get(key)) |entry| {
        return entry.status;
    }

    // Start new load (check capacity limit per CLAUDE.md)
    if (g_pending_loads.count() >= MAX_PENDING_LOADS) {
        wasm_imports.err("WASM image loader: max pending loads ({d}) reached", .{MAX_PENDING_LOADS});
        return .failed;
    }

    // Store context for callback
    g_gooey_ctx = gooey_ctx;

    // Start async fetch
    const request_id = wasm_loader.loadFromUrlAsync(source, onWasmImageLoaded) orelse {
        wasm_imports.err("WASM image loader: failed to start load for {s}", .{source});
        return .failed;
    };

    // Track the pending load (keyed by full ImageKey to avoid collisions)
    g_pending_loads.put(key, .{
        .request_id = request_id,
        .status = .loading,
    }) catch {
        wasm_imports.err("WASM image loader: failed to track load for {s}", .{source});
        return .failed;
    };

    return .loading;
}

/// Callback when WASM image load completes
fn onWasmImageLoaded(request_id: u32, result: ?wasm_loader.DecodedImage) void {
    // Assert loader is initialized (per CLAUDE.md: minimum 2 assertions per function)
    std.debug.assert(g_wasm_loader_initialized);
    std.debug.assert(g_allocator != null); // Allocator must be set during init

    // Find the pending entry by request_id
    var found_key: ?image_mod.ImageKey = null;

    var iter = g_pending_loads.iterator();
    while (iter.next()) |entry| {
        if (entry.value_ptr.request_id == request_id) {
            found_key = entry.key_ptr.*;
            break;
        }
    }

    if (found_key == null) {
        // Request was cancelled or unknown - clean up decoded image
        if (result) |decoded| {
            if (g_allocator) |alloc| {
                var mutable = decoded;
                mutable.deinit(alloc);
            }
        }
        return;
    }

    const key = found_key.?;

    if (result) |decoded| {
        // Assert decoded image has valid dimensions
        std.debug.assert(decoded.width > 0);
        std.debug.assert(decoded.height > 0);

        // Cache the decoded image
        var cache_success = false;
        if (g_gooey_ctx) |gooey_ctx| {
            cache_success = if (gooey_ctx.image_atlas.*.cacheRgba(
                key,
                decoded.width,
                decoded.height,
                decoded.pixels,
            )) |_| true else |_| false;

            // Request redraw to show the loaded image
            if (cache_success) {
                gooey_ctx.requestRender();
            }
        }

        // Free decoded image memory
        if (g_allocator) |alloc| {
            var mutable = decoded;
            mutable.deinit(alloc);
        }

        // Remove completed entry from pending loads
        // Entry is no longer needed - image is cached or failed
        _ = g_pending_loads.remove(key);

        if (!cache_success) {
            wasm_imports.err("WASM image loader: failed to cache image for request {d}", .{request_id});
        }
    } else {
        // Load failed - remove from pending so it can be retried later
        _ = g_pending_loads.remove(key);
        wasm_imports.err("WASM image loader: load failed for request {d}", .{request_id});
    }
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
