//! Web/WASM Clipboard Support
//!
//! Provides clipboard access for web platform.
//!
//! Write (copy): Uses navigator.clipboard.writeText() via JS import.
//! Read (paste): Handled by JS paste event -> appendText flow.
//!               The browser's paste event gives synchronous access to
//!               clipboardData, which is then injected as text input, so
//!               there is no read function.

const imports = @import("imports.zig");

/// Write text to the system clipboard.
/// This is fire-and-forget on web - the JS side handles async.
/// Returns true optimistically (actual write may fail silently).
pub fn setText(text: []const u8) bool {
    if (text.len == 0) return true;
    imports.clipboardWriteText(text.ptr, @intCast(text.len));
    return true;
}
