const imports = @import("imports.zig");

pub fn setText(text: []const u8) bool {
    if (text.len == 0) return true;
    imports.clipboardWriteText(text.ptr, @intCast(text.len));
    return true;
}
