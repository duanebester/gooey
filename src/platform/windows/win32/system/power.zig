//! SHIM: system/power.zig from the generated package.
//!
//! `ui/windows_and_messaging.zig` imports one enum from `system/power.zig`;
//! the real file (1.9k lines) pulls in devices/registry cascades nothing in
//! gooey's windowing uses. Definition copied verbatim from the source
//! package (`win32-25.0.28-preview`, system/power.zig:174).

pub const POWER_SETTING_REGISTER_NOTIFICATION_FLAGS = enum(u32) {
    SERVICE_HANDLE = 1,
    CALLBACK = 2,
    _,
};
