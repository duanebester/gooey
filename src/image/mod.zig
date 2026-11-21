//! Decoding is `core/images.zig`'s worker; `loader.zig` holds the platform
//! decoder it calls.

pub const ImageAtlas = @import("atlas.zig").ImageAtlas;
pub const ImageKey = @import("atlas.zig").ImageKey;
pub const CachedImage = @import("atlas.zig").CachedImage;
pub const ImageSource = @import("atlas.zig").ImageSource;
pub const ImageData = @import("atlas.zig").ImageData;
pub const ObjectFit = @import("atlas.zig").ObjectFit;

pub const loader = @import("loader.zig");
