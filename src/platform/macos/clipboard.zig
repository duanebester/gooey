const std = @import("std");
const objc = @import("objc");
const core_clipboard = @import("../../core/clipboard.zig");

extern "c" var NSPasteboardTypeString: objc.c.id;

pub fn readText(out: []u8) u32 {
    std.debug.assert(out.len > 0);
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return 0;
    const pasteboard = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});
    const ns_string_id: objc.c.id = pasteboard.msgSend(
        objc.c.id,
        "stringForType:",
        .{NSPasteboardTypeString},
    );
    if (ns_string_id == null) return 0;
    const ns_string = objc.Object.fromId(ns_string_id);
    const cstr = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{}) orelse return 0;
    const value = std.mem.span(cstr);
    const kept = core_clipboard.prefixFitting(value, out.len);
    @memcpy(out[0..kept], value[0..kept]);
    std.debug.assert(kept <= out.len);
    return @intCast(kept);
}

pub fn setText(text: []const u8) bool {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return false;
    const NSString = objc.getClass("NSString") orelse return false;

    const pasteboard = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});

    _ = pasteboard.msgSend(c_long, "clearContents", .{});

    const ns_string_id: objc.c.id = NSString.msgSend(objc.c.id, "alloc", .{});
    if (ns_string_id == null) return false;

    const ns_string = objc.Object.fromId(ns_string_id);
    const initialized_id: objc.c.id = ns_string.msgSend(
        objc.c.id,
        "initWithBytes:length:encoding:",
        .{
            text.ptr,
            @as(c_ulong, text.len),
            @as(c_ulong, 4),
        },
    );
    if (initialized_id == null) return false;

    const initialized = objc.Object.fromId(initialized_id);

    return pasteboard.msgSend(bool, "setString:forType:", .{
        initialized.value,
        NSPasteboardTypeString,
    });
}

test "clipboard round-trip" {
    const test_text = "Hello from Gooey clipboard test! 🎉";

    const write_ok = setText(test_text);
    if (!write_ok) {
        return;
    }

    var out: [64]u8 = undefined;
    const len = readText(&out);
    try std.testing.expectEqualStrings(test_text, out[0..len]);
}
