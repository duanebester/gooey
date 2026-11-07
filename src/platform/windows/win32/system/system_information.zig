//! SHIM: system/system_information.zig from the generated package.
//!
//! `system/threading.zig` imports two small types from
//! `system/system_information.zig`. Definitions copied verbatim from the
//! source package (`win32-25.0.28-preview`, system/system_information.zig).

pub const GROUP_AFFINITY = extern struct {
    Mask: usize,
    Group: u16,
    Reserved: [3]u16,
};

pub const IMAGE_FILE_MACHINE = enum(u16) {
    AXP64 = 644,
    I386 = 332,
    IA64 = 512,
    AMD64 = 34404,
    UNKNOWN = 0,
    TARGET_HOST = 1,
    _,
};
