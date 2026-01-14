//! Images WASM Example - Async URL Loading
//!
//! Demonstrates async image loading from URLs on WASM/WebGPU.
//! Uses picsum.photos placeholder API to fetch real images.
//!
//! Features:
//! - Async fetch from URLs using browser fetch API
//! - Loading state management with placeholder boxes
//! - Image caching in atlas after load
//! - Corner radius, opacity effects on loaded images

const std = @import("std");
const gooey = @import("gooey");
const ui = gooey.ui;
const platform = gooey.platform;

const Color = gooey.Color;
const Cx = gooey.Cx;

const image_mod = gooey.image;
const wasm_loader = gooey.wasm_image_loader;
const ImageKey = image_mod.ImageKey;

// =============================================================================
// Image Loading State
// =============================================================================

const LoadingState = enum {
    not_started,
    loading,
    loaded,
    failed,
};

const AsyncImage = struct {
    url: []const u8,
    state: LoadingState = .not_started,
    request_id: ?u32 = null,
    // Cached key for looking up in atlas
    cache_key: ?ImageKey = null,
};

// =============================================================================
// App State
// =============================================================================

const AppState = struct {
    initialized: bool = false,
    images: [6]AsyncImage = undefined,
};

var state = AppState{};

// Global allocator for callbacks (set during init)
var g_allocator: std.mem.Allocator = undefined;
var g_cx: ?*Cx = null;

// =============================================================================
// Image URLs - Using picsum.photos placeholder service
// =============================================================================

const IMAGE_URLS = [_][]const u8{
    "https://picsum.photos/id/237/400/400", // Dog
    "https://picsum.photos/id/1015/400/400", // River landscape
    "https://picsum.photos/id/1025/400/400", // Pug portrait
    "https://picsum.photos/id/1011/400/400", // Boat
    "https://picsum.photos/id/1039/400/400", // Foggy road
    "https://picsum.photos/id/1029/400/400", // Lake house
};

// =============================================================================
// App Definition
// =============================================================================

const App = gooey.App(AppState, &state, render, .{
    .title = "Images Demo - Async URL Loading (WASM)",
    .width = 900,
    .height = 700,
    .background_color = Color.fromHex("#1a1a2e"),
    .init = initApp,
});

fn initApp(cx: *Cx) void {
    g_allocator = cx.allocator();

    // Initialize the WASM image loader
    wasm_loader.init(g_allocator);

    // Setup image entries
    for (IMAGE_URLS, 0..) |url, i| {
        state.images[i] = .{
            .url = url,
            .state = .not_started,
        };
    }

    state.initialized = true;
}

// =============================================================================
// Async Image Loading
// =============================================================================

fn startLoadingImage(index: usize, cx: *Cx) void {
    if (index >= state.images.len) return;

    var img = &state.images[index];
    if (img.state != .not_started) return;

    img.state = .loading;

    // Store cx for callback (in real app, use proper state management)
    g_cx = cx;

    if (platform.is_wasm) {
        // Create callback that captures the index
        const callbacks = struct {
            fn callback0(request_id: u32, result: ?wasm_loader.DecodedImage) void {
                handleImageLoaded(0, request_id, result);
            }
            fn callback1(request_id: u32, result: ?wasm_loader.DecodedImage) void {
                handleImageLoaded(1, request_id, result);
            }
            fn callback2(request_id: u32, result: ?wasm_loader.DecodedImage) void {
                handleImageLoaded(2, request_id, result);
            }
            fn callback3(request_id: u32, result: ?wasm_loader.DecodedImage) void {
                handleImageLoaded(3, request_id, result);
            }
            fn callback4(request_id: u32, result: ?wasm_loader.DecodedImage) void {
                handleImageLoaded(4, request_id, result);
            }
            fn callback5(request_id: u32, result: ?wasm_loader.DecodedImage) void {
                handleImageLoaded(5, request_id, result);
            }
        };

        const callback_fns = [_]wasm_loader.DecodeCallback{
            callbacks.callback0,
            callbacks.callback1,
            callbacks.callback2,
            callbacks.callback3,
            callbacks.callback4,
            callbacks.callback5,
        };

        img.request_id = wasm_loader.loadFromUrlAsync(img.url, callback_fns[index]);
    }
}

fn handleImageLoaded(index: usize, request_id: u32, result: ?wasm_loader.DecodedImage) void {
    if (index >= state.images.len) return;

    var img = &state.images[index];

    // Verify request ID matches
    if (img.request_id != request_id) return;

    if (result) |decoded| {
        // Cache the decoded image in the atlas
        if (g_cx) |cx| {
            const key = ImageKey.init(
                .{ .url = img.url },
                null,
                null,
                cx.gooey().scale_factor,
            );

            // Cache the RGBA pixels in the atlas
            _ = cx.gooey().image_atlas.*.cacheRgba(
                key,
                decoded.width,
                decoded.height,
                decoded.pixels,
            ) catch {
                img.state = .failed;
                return;
            };

            img.cache_key = key;
            img.state = .loaded;
        } else {
            img.state = .failed;
        }

        // Free the decoded pixels (we've copied to atlas)
        var mutable_decoded = decoded;
        mutable_decoded.deinit(g_allocator);
    } else {
        img.state = .failed;
    }
}

// =============================================================================
// Main Render
// =============================================================================

fn render(cx: *Cx) void {
    // Start loading any images that haven't started
    for (0..state.images.len) |i| {
        if (state.images[i].state == .not_started) {
            startLoadingImage(i, cx);
        }
    }

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
        ui.text("Loading images from picsum.photos...", .{
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
        cx.render(ui.scroll("images_scroll", .{
            .width = 852,
            .height = 560,
            .background = Color.fromHex("#1a1a2e"),
            .padding = .{ .all = 4 },
            .gap = 24,
            .content_height = 900,
            .track_color = Color.fromHex("#16213e"),
            .thumb_color = Color.fromHex("#4a4a6a"),
        }, .{
            SectionImages{},
            SectionCornerRadius{},
            SectionEffects{},
        }));
    }
};

// =============================================================================
// Section: Loaded Images
// =============================================================================

const SectionImages = struct {
    pub fn render(_: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 12, .fill_width = true }, .{
            ui.text("Loaded Images", .{
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
            .alignment = .{ .cross = .end },
        }, .{
            ImageItem{ .index = 0, .label = "Square" },
            ImageItem{ .index = 1, .label = "Landscape" },
            ImageItem{ .index = 2, .label = "Portrait" },
        }));
    }
};

const ImageItem = struct {
    index: usize,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        const img = &state.images[self.index];

        cx.render(ui.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            ImageOrPlaceholder{ .index = self.index },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
            StatusText{ .state = img.state },
        }));
    }
};

const ImageOrPlaceholder = struct {
    index: usize,

    pub fn render(self: @This(), cx: *Cx) void {
        const img = &state.images[self.index];

        switch (img.state) {
            .loaded => {
                // Render actual image using the cached key
                cx.render(ui.box(.{
                    .width = 150,
                    .height = 150,
                    .background = Color.fromHex("#2a2a4e"),
                    .corner_radius = 4,
                }, .{
                    ui.ImagePrimitive{
                        .source = img.url,
                        .width = 150,
                        .height = 150,
                        .fit = .cover,
                    },
                }));
            },
            .loading => {
                // Animated loading placeholder
                const placeholder = LoadingPlaceholder{ .size = 150 };
                placeholder.render(cx);
            },
            .failed => {
                // Error state
                cx.render(ui.box(.{
                    .width = 150,
                    .height = 150,
                    .background = Color.fromHex("#4a2020"),
                    .corner_radius = 4,
                    .alignment = .{ .main = .center, .cross = .center },
                }, .{
                    ui.text("Failed", .{ .size = 12, .color = Color.fromHex("#ff6666") }),
                }));
            },
            .not_started => {
                // Waiting to start
                cx.render(ui.box(.{
                    .width = 150,
                    .height = 150,
                    .background = Color.fromHex("#2a2a4e"),
                    .corner_radius = 4,
                }, .{}));
            },
        }
    }
};

const LoadingPlaceholder = struct {
    size: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .background = Color.fromHex("#3a3a5e"),
            .corner_radius = 4,
            .alignment = .{ .main = .center, .cross = .center },
        }, .{
            // Pulsing inner box
            PulsingBox{ .size = self.size * 0.3 },
        }));
    }
};

const PulsingBox = struct {
    size: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .background = Color.fromHex("#5a5a8e"),
            .corner_radius = self.size * 0.2,
        }, .{}));
    }
};

const StatusText = struct {
    state: LoadingState,

    pub fn render(self: @This(), cx: *Cx) void {
        const text_str = switch (self.state) {
            .not_started => "Waiting...",
            .loading => "Loading...",
            .loaded => "Loaded!",
            .failed => "Error",
        };
        const color = switch (self.state) {
            .not_started => Color.fromHex("#666666"),
            .loading => Color.fromHex("#f7a41d"),
            .loaded => Color.fromHex("#44ff88"),
            .failed => Color.fromHex("#ff6666"),
        };

        cx.render(ui.box(.{}, .{
            ui.text(text_str, .{ .size = 10, .color = color }),
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
            RadiusItem{ .index = 3, .radius = 0, .label = "none" },
            RadiusItem{ .index = 3, .radius = 8, .label = "8px" },
            RadiusItem{ .index = 3, .radius = 20, .label = "20px" },
            RadiusItem{ .index = 3, .radius = 40, .label = "circle" },
        }));
    }
};

const RadiusItem = struct {
    index: usize,
    radius: f32,
    label: []const u8,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            RadiusImageOrPlaceholder{
                .index = self.index,
                .radius = self.radius,
            },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
        }));
    }
};

const RadiusImageOrPlaceholder = struct {
    index: usize,
    radius: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        const img = &state.images[self.index];
        if (img.state == .loaded) {
            const rounded = RoundedImage{ .index = self.index, .radius = self.radius };
            rounded.render(cx);
        } else {
            const placeholder = PlaceholderBox{ .size = 80, .radius = self.radius };
            placeholder.render(cx);
        }
    }
};

const RoundedImage = struct {
    index: usize,
    radius: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        const img = &state.images[self.index];
        cx.render(ui.box(.{
            .width = 80,
            .height = 80,
            .corner_radius = self.radius,
        }, .{
            ui.ImagePrimitive{
                .source = img.url,
                .width = 80,
                .height = 80,
                .fit = .cover,
                .corner_radius = gooey.CornerRadius.all(self.radius),
            },
        }));
    }
};

const PlaceholderBox = struct {
    size: f32,
    radius: f32,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{
            .width = self.size,
            .height = self.size,
            .corner_radius = self.radius,
            .background = Color.fromHex("#3a3a5e"),
        }, .{}));
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
            EffectItem{ .index = 4, .label = "Normal", .opacity = 1.0, .grayscale = 0, .tint = null },
            EffectItem{ .index = 4, .label = "50% Opacity", .opacity = 0.5, .grayscale = 0, .tint = null },
            EffectItem{ .index = 4, .label = "Grayscale", .opacity = 1.0, .grayscale = 1.0, .tint = null },
            EffectItem{ .index = 4, .label = "Blue Tint", .opacity = 1.0, .grayscale = 0, .tint = Color.fromHex("#4488ff") },
            EffectItem{ .index = 4, .label = "Combined", .opacity = 0.8, .grayscale = 0.5, .tint = Color.fromHex("#ff8844") },
        }));
    }
};

const EffectItem = struct {
    index: usize,
    label: []const u8,
    opacity: f32,
    grayscale: f32,
    tint: ?Color,

    pub fn render(self: @This(), cx: *Cx) void {
        cx.render(ui.box(.{ .gap = 8, .alignment = .{ .cross = .center } }, .{
            EffectImageOrPlaceholder{
                .index = self.index,
                .opacity = self.opacity,
                .grayscale = self.grayscale,
                .tint = self.tint,
            },
            ui.text(self.label, .{ .size = 12, .color = Color.fromHex("#666666") }),
        }));
    }
};

const EffectImageOrPlaceholder = struct {
    index: usize,
    opacity: f32,
    grayscale: f32,
    tint: ?Color,

    pub fn render(self: @This(), cx: *Cx) void {
        const img = &state.images[self.index];
        if (img.state == .loaded) {
            const effect = EffectImage{
                .index = self.index,
                .opacity = self.opacity,
                .grayscale = self.grayscale,
                .tint = self.tint,
            };
            effect.render(cx);
        } else {
            const placeholder = EffectPlaceholder{
                .opacity = self.opacity,
                .tint = self.tint,
            };
            placeholder.render(cx);
        }
    }
};

const EffectImage = struct {
    index: usize,
    opacity: f32,
    grayscale: f32,
    tint: ?Color,

    pub fn render(self: @This(), cx: *Cx) void {
        const img = &state.images[self.index];
        cx.render(ui.box(.{
            .width = 100,
            .height = 60,
            .corner_radius = 8,
        }, .{
            ui.ImagePrimitive{
                .source = img.url,
                .width = 100,
                .height = 60,
                .fit = .cover,
                .corner_radius = gooey.CornerRadius.all(8),
                .opacity = self.opacity,
                .grayscale = self.grayscale,
                .tint = self.tint,
            },
        }));
    }
};

const EffectPlaceholder = struct {
    opacity: f32,
    tint: ?Color,

    pub fn render(self: @This(), cx: *Cx) void {
        const base_color = self.tint orelse Color.fromHex("#f7a41d");
        cx.render(ui.box(.{
            .width = 100,
            .height = 60,
            .corner_radius = 8,
            .background = base_color.withAlpha(self.opacity),
        }, .{}));
    }
};

// =============================================================================
// Entry Points
// =============================================================================

// Force type analysis - triggers @export on WASM
comptime {
    _ = App;
}

// Native entry point
pub fn main() !void {
    if (platform.is_wasm) unreachable;
    return App.main();
}
