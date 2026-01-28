//! Web/WASM Clipboard Support
//!
//! Provides clipboard access for web platform.
//!
//! Write (copy): Uses navigator.clipboard.writeText() via JS import.
//! Read (paste): Handled by JS paste event -> appendText flow.
//!               The browser's paste event gives synchronous access to
//!               clipboardData, which is then injected as text input.

const imports = @import("imports.zig");

/// Write text to the system clipboard.
/// This is fire-and-forget on web - the JS side handles async.
/// Returns true optimistically (actual write may fail silently).
pub fn setText(text: []const u8) bool {
    if (text.len == 0) return true;
    imports.clipboardWriteText(text.ptr, @intCast(text.len));
    return true;
}

/// Read text from the system clipboard.
/// On web, this returns null because paste is handled differently:
/// The browser's paste event on the hidden input element captures
/// the clipboard text synchronously and injects it via appendText().
/// This avoids the async permission issues with navigator.clipboard.readText().
pub fn getText(_: anytype) ?[]const u8 {
    return null;
}
