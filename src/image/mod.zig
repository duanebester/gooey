//! Image rendering module
//!
//! Provides atlas-cached image rendering with support for:
//! - PNG/JPEG image loading
//! - Texture atlas caching
//! - Tinting, opacity, and grayscale effects
//! - Rounded corners

pub const ImageAtlas = @import("atlas.zig").ImageAtlas;
pub const ImageKey = @import("atlas.zig").ImageKey;
pub const CachedImage = @import("atlas.zig").CachedImage;
pub const ImageSource = @import("atlas.zig").ImageSource;
pub const ImageData = @import("atlas.zig").ImageData;
pub const ObjectFit = @import("atlas.zig").ObjectFit;

pub const loader = @import("loader.zig");
