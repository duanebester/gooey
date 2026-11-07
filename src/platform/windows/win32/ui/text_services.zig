//! SHIM: ui/text_services.zig from the generated package.
//!
//! `ui/input/keyboard_and_mouse.zig` imports `HKL` from
//! `ui/text_services.zig`; the real file pulls in system/com cascades
//! nothing in gooey's windowing uses. Definition copied verbatim from the
//! source package (`win32-25.0.28-preview`, ui/text_services.zig:663).

pub const HKL = *opaque{};
