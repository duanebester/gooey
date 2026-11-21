const imports = @import("imports.zig");

/// Fire-and-forget: the JS write is async, so `true` is optimistic.
pub fn setText(text: []const u8) bool {
    if (text.len == 0) return true;
    imports.clipboardWriteText(text.ptr, @intCast(text.len));
    return true;
}
