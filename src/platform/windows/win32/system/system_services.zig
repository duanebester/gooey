//! SHIM: system/system_services.zig from the generated package.
//!
//! `system/threading.zig` imports one enum from `system/system_services.zig`.
//! Definition copied verbatim from the source package
//! (`win32-25.0.28-preview`, system/system_services.zig).

pub const RTL_UMS_SCHEDULER_REASON = enum(i32) {
    Startup = 0,
    ThreadBlocked = 1,
    ThreadYield = 2,
};
