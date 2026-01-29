//! macOS Clipboard (Pasteboard) Support
//!
//! Provides simple text clipboard access using NSPasteboard.
//! Uses the general (system) pasteboard for copy/paste operations.

const std = @import("std");
const objc = @import("objc");

// AppKit constant for string pasteboard type
extern "c" var NSPasteboardTypeString: objc.c.id;

/// Read text from the system clipboard.
/// Returns owned slice that caller must free, or null if no text available.
pub fn getText(allocator: std.mem.Allocator) ?[]const u8 {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return null;
    const pasteboard = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});

    // stringForType: returns NSString* or nil
    const ns_string_id: objc.c.id = pasteboard.msgSend(
        objc.c.id,
        "stringForType:",
        .{NSPasteboardTypeString},
    );
    if (ns_string_id == null) return null;

    const ns_string = objc.Object{ .value = ns_string_id };

    // Get UTF-8 C string
    const cstr: ?[*:0]const u8 = ns_string.msgSend(?[*:0]const u8, "UTF8String", .{});
    if (cstr == null) return null;

    // Copy to owned slice (NSString's UTF8String is autoreleased)
    return allocator.dupe(u8, std.mem.span(cstr.?)) catch null;
}

/// Write text to the system clipboard.
/// Returns true on success.
pub fn setText(text: []const u8) bool {
    const NSPasteboard = objc.getClass("NSPasteboard") orelse return false;
    const NSString = objc.getClass("NSString") orelse return false;

    const pasteboard = NSPasteboard.msgSend(objc.Object, "generalPasteboard", .{});

    // Clear existing contents (required before writing)
    _ = pasteboard.msgSend(c_long, "clearContents", .{});

    // Create NSString from our text - need null-terminated string
    // Since text may not be null-terminated, we use initWithBytes:length:encoding:
    const ns_string_id: objc.c.id = NSString.msgSend(objc.c.id, "alloc", .{});
    if (ns_string_id == null) return false;

    const ns_string = objc.Object{ .value = ns_string_id };
    const initialized_id: objc.c.id = ns_string.msgSend(
        objc.c.id,
        "initWithBytes:length:encoding:",
        .{
            text.ptr,
            @as(c_ulong, text.len),
            @as(c_ulong, 4), // NSUTF8StringEncoding = 4
        },
    );
    if (initialized_id == null) return false;

    const initialized = objc.Object{ .value = initialized_id };

    // Write to pasteboard
    return pasteboard.msgSend(bool, "setString:forType:", .{
        initialized.value,
        NSPasteboardTypeString,
    });
}

// =============================================================================
// Tests
// =============================================================================

test "clipboard round-trip" {
    const allocator = std.testing.allocator;

    const test_text = "Hello from Gooey clipboard test! 🎉";

    // Write to clipboard
    const write_ok = setText(test_text);
    if (!write_ok) {
        // Skip test if clipboard not available (e.g., headless CI)
        return;
    }

    // Read back
    const read_text = getText(allocator) orelse {
        try std.testing.expect(false); // Should have read something
        return;
    };
    defer allocator.free(read_text);

    try std.testing.expectEqualStrings(test_text, read_text);
}
