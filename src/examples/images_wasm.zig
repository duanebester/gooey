//! Images WASM Example - Async URL Loading (auto-routed)
//!
//! Demonstrates async image loading from URLs on WASM/WebGPU.
//! Uses picsum.photos placeholder API to fetch real images.
//!
//! ## What this example shows
//!
//! As of Task 4.6 of the Io migration, `ui.ImagePrimitive` with a URL source
//! "just works" on both native and WASM — identical to the native flow from
//! the application's perspective. There is no per-example plumbing:
//!
//! - No `wasm_image_loader.init()` call.
//! - No per-image `request_id` tracking.
//! - No hand-written N-way callback dispatch.
//! - No manual `cacheRgba` into the atlas.
//! - No `LoadingState` enum threading through every component.
//!
//! The framework handles all of this inside `renderImage`:
//!
//! 1. `renderImage` sees a URL source, misses the atlas cache.
//! 2. On WASM, it calls `ensureWasmImageLoading` which in turn calls
//!    `wasm_image_loader.loadFromUrlAsync` (browser `fetch` +
//!    `createImageBitmap`).
//! 3. While the fetch is in flight, `renderImagePlaceholder` draws a gray
//!    box (configurable via `.placeholder_color`).
//! 4. When JS calls back into WASM with decoded pixels, the loader caches
//!    into the atlas and requests a redraw.
//! 5. Next frame: atlas hit, the image renders normally with full support
//!    for `fit`, `corner_radius`, `opacity`, `grayscale`, `tint`, etc.
//!
//! Compare this file to `git log` history for the old pattern — most of the
//! boilerplate that used to live here is now gone.
//!
//! Features still demonstrated:
//! - Multiple concurrent URL fetches (pending set dedupes per URL).
//! - Corner radius on loaded images.
//! - Visual effects (opacity, grayscale, tint) composed with image loading.
//! - Custom placeholder color while loading.

const std = @import("std");

const gooey = @import("gooey");

/// WASM-compatible logging — redirect std.log to console.log via JS imports.
pub const std_options = gooey.std_options;
const ui = gooey.ui;
const platform = gooey.platform;

const Color = gooey.Color;
const Cx = gooey.Cx;

// =============================================================================
// App State
// =============================================================================

/// Intentionally empty — the framework owns all image-loading state now.
/// Kept as a struct so the `gooey.App(...)` type signature stays recognisable
/// for readers coming from other examples.
const AppState = struct {};

var state = AppState{};

// =============================================================================
// Image URLs — picsum.photos placeholder service
// =============================================================================

const IMAGE_URLS = [_][]const u8{
    "https://picsum.photos/id/237/400/400", // Dog
    "https://picsum.photos/id/1015/400/400", // River landscape
    "https://picsum.photos/id/1025/400/400", // Pug portrait
    "https://picsum.photos/id/1011/400/400", // Boat
    "https://picsum.photos/id/1039/400/400", // Foggy road
    "https://picsum.photos/id/1029/400/400", // Lake house
};

/// Background colour used for the loading placeholder box. Passing this to
/// `ImagePrimitive.placeholder_color` lets us theme the placeholder to match
/// the surrounding UI instead of the default light-gray.
const PLACEHOLDER_BG = Color.fromHex("#2a2a4e");

// =============================================================================
// App Definition
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Images Demo - Async URL Loading (WASM)",
    .width = 900,
    .height = 700,
    .background_color = Color.fromHex("#1a1a2e"),
});

// =============================================================================
// Main Render
// =============================================================================

fn render(cx: *Cx) void {
    cx.render(ui.box(.{
        .padding = .{ .all = 24 },
        .gap = 16,
        .background = Color.fromHex("#1a1a2e"),
    }, .{
        ui.text("Async Image Loading Demo (WASM)", .{
            .size = 24,
            .color = Color.white,
            .weight = .bold,
        }),
        ui.text("URLs load automatically via the framework's built-in WASM loader.", .{
            .size = 14,
            .color = Color.fromHex("#888888"),
        }),
        ScrollContent{},
    }));
}

// =============================================================================
// Scroll Container
// =============================================================================

const ScrollContent = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .gap = 24,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#0f0f1e"),
            .corner_radius = 12,
            .fill_width = true,
        }, .{
            SectionImages{},
            SectionCornerRadius{},
            SectionEffects{},
        }));
    }
};

// =============================================================================
// Section: Basic Image Grid
// =============================================================================

const SectionImages = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Images from URLs", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            ImagesRow{},
        }));
    }
};

const ImagesRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            ImageItem{ .index = 0, .label = "Dog" },
            ImageItem{ .index = 1, .label = "River" },
            ImageItem{ .index = 2, .label = "Pug" },
            ImageItem{ .index = 3, .label = "Boat" },
            ImageItem{ .index = 4, .label = "Fog" },
            ImageItem{ .index = 5, .label = "Lake" },
        }));
    }
};

const ImageItem = struct {
    index: usize,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            // One ImagePrimitive — that's the whole integration.
            // The framework handles fetch + decode + atlas caching + placeholder.
            ui.ImagePrimitive{
                .source = IMAGE_URLS[self.index],
                .width = 150,
                .height = 150,
                .fit = .cover,
                .placeholder_color = PLACEHOLDER_BG,
            },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
        }));
    }
};

// =============================================================================
// Section: Corner Radius on Loaded Images
// =============================================================================

const SectionCornerRadius = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Corner Radius", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            CornerRadiusRow{},
        }));
    }
};

const CornerRadiusRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            RadiusItem{ .radius = 0, .label = "none" },
            RadiusItem{ .radius = 8, .label = "8px" },
            RadiusItem{ .radius = 20, .label = "20px" },
            RadiusItem{ .radius = 40, .label = "circle" },
        }));
    }
};

const RadiusItem = struct {
    radius: f32,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            ui.ImagePrimitive{
                .source = IMAGE_URLS[3], // Boat — consistent subject per row.
                .width = 80,
                .height = 80,
                .fit = .cover,
                .corner_radius = gooey.CornerRadius.all(self.radius),
                .placeholder_color = PLACEHOLDER_BG,
            },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
        }));
    }
};

// =============================================================================
// Section: Visual Effects
// =============================================================================

const SectionEffects = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Visual Effects", .{
                .size = 16,
                .color = Color.fromHex("#888888"),
                .weight = .medium,
            }),
            EffectsRow{},
        }));
    }
};

const EffectsRow = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .direction = .row,
            .gap = 16,
            .padding = .{ .all = 16 },
            .background = Color.fromHex("#16213e"),
            .corner_radius = 8,
        }, .{
            EffectItem{ .label = "Normal", .opacity = 1.0, .grayscale = 0, .tint = null },
            EffectItem{ .label = "50% Opacity", .opacity = 0.5, .grayscale = 0, .tint = null },
            EffectItem{ .label = "Grayscale", .opacity = 1.0, .grayscale = 1.0, .tint = null },
            EffectItem{ .label = "Blue Tint", .opacity = 1.0, .grayscale = 0, .tint = Color.fromHex("#4488ff") },
            EffectItem{ .label = "Combined", .opacity = 0.8, .grayscale = 0.5, .tint = Color.fromHex("#ff8844") },
        }));
    }
};

const EffectItem = struct {
    label: []const u8,
    opacity: f32,
    grayscale: f32,
    tint: ?Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            ui.ImagePrimitive{
                .source = IMAGE_URLS[4], // Fog — same image across effects.
                .width = 100,
                .height = 60,
                .fit = .cover,
                .corner_radius = gooey.CornerRadius.all(8),
                .opacity = self.opacity,
                .grayscale = self.grayscale,
                .tint = self.tint,
                .placeholder_color = PLACEHOLDER_BG,
            },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
        }));
    }
};

// =============================================================================
// Entry Points
// =============================================================================

// Force type analysis — triggers @export on WASM.
comptime {
    _ = App;
}

// Native entry point.
pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
