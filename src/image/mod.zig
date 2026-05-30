//! Image rendering module
//!
//! Provides atlas-cached image rendering with support for:
//! - PNG/JPEG image loading
//! - Texture atlas caching
//! - Tinting, opacity, and grayscale effects
//! - Rounded corners
//!
//! Async URL loading is owned by `ImageLoader`, a self-contained
//! subsystem that fetches URLs in the background, drains completed
//! loads each frame, and caches decoded pixels into the atlas. See
//! `loader.zig` for the implementation.

pub const ImageAtlas = @import("atlas.zig").ImageAtlas;
pub const ImageKey = @import("atlas.zig").ImageKey;
pub const CachedImage = @import("atlas.zig").CachedImage;
pub const ImageSource = @import("atlas.zig").ImageSource;
pub const ImageData = @import("atlas.zig").ImageData;
pub const ObjectFit = @import("atlas.zig").ObjectFit;

pub const loader = @import("loader.zig");

// Async URL loading subsystem (PR 1 — extracted from `Gooey`).
//
// Re-exported at the module root so callers can write
// `image_mod.ImageLoader` / `image_mod.MAX_PENDING_IMAGE_LOADS` instead
// of the longer `image_mod.loader.ImageLoader`. Keeps the parent
// context's import surface narrow.
pub const ImageLoader = loader.ImageLoader;
pub const ImageLoadResult = loader.ImageLoadResult;
pub const MAX_IMAGE_LOAD_RESULTS = loader.MAX_IMAGE_LOAD_RESULTS;
pub const MAX_PENDING_IMAGE_LOADS = loader.MAX_PENDING_IMAGE_LOADS;
pub const MAX_FAILED_IMAGE_LOADS = loader.MAX_FAILED_IMAGE_LOADS;

// Generic asset cache skeleton — fleshed out in PR 2 (SVG consolidation).
// Re-exported here so PR 2's call sites can `image_mod.AssetCache(...)` without
// reaching into a sibling module.
pub const asset_cache = @import("asset_cache.zig");
pub const AssetCache = asset_cache.AssetCache;
