//! Handler - Function pointer storage for UI callbacks
//!
//! Handlers are created through Cx methods:
//! - `cx.update(method)` - pure state mutation
//! - `cx.updateWith(arg, method)` - mutation with argument
//! - `cx.command(method)` - needs framework access
//! - `cx.commandWith(arg, method)` - framework access with argument
//!
//! Example:
//! ```zig
//! const AppState = struct {
//!     count: i32 = 0,
//!
//!     pub fn increment(self: *AppState) void {
//!         self.count += 1;
//!     }
//! };
//!
//! fn render(cx: *Cx) void {
//!     const s = cx.state(AppState);
//!     cx.render(ui.box(.{}, .{
//!         Button{ .label = "+", .on_click_handler = cx.update(AppState.increment) },
//!     }));
//! }
//! ```

const std = @import("std");
const Gooey = @import("gooey.zig").Gooey;
const entity_mod = @import("entity.zig");
pub const EntityId = entity_mod.EntityId;

/// Type-erased handler reference that can be stored and invoked later.
///
/// The callback receives a `*Gooey` pointer and optional entity ID.
pub const HandlerRef = struct {
    /// The actual callback function (receives Gooey and entity ID)
    callback: *const fn (*Gooey, EntityId) void,

    /// Entity ID this handler operates on (invalid = use root state)
    entity_id: EntityId = EntityId.invalid,

    /// Invoke this handler
    pub fn invoke(self: HandlerRef, gooey: *Gooey) void {
        self.callback(gooey, self.entity_id);
    }
};

/// Handler template for index-based selection (used by Select, TabBar, etc.).
///
/// Captures the comptime callback but defers the index argument, allowing
/// widgets to generate per-option `HandlerRef`s internally.
///
/// Created via `cx.onSelect(State.method)`.
pub const OnSelectHandler = struct {
    /// Callback that unpacks a packed index (and optional id hash) from EntityId.
    /// Generated at comptime by `Cx.onSelect`.
    callback: *const fn (*Gooey, EntityId) void,

    /// Create a HandlerRef for a specific option index.
    ///
    /// Use when the caller manages open/close state externally.
    pub fn forIndex(self: OnSelectHandler, index: usize) HandlerRef {
        return .{
            .callback = self.callback,
            .entity_id = packArg(usize, index),
        };
    }

    /// Create a HandlerRef that selects an option AND closes internal state.
    ///
    /// Packs both the option index (lower 32 bits) and the select's id hash
    /// (upper 32 bits) into the EntityId. The comptime-generated callback
    /// unpacks both, calls the user method, and closes the widget.
    pub fn forIndexAndClose(self: OnSelectHandler, index: u32, id_hash: u32) HandlerRef {
        std.debug.assert(id_hash != 0); // id_hash 0 is reserved (LayoutId.none)
        return .{
            .callback = self.callback,
            .entity_id = .{ .id = @as(u64, id_hash) << 32 | @as(u64, index) },
        };
    }

    /// Unpack the option index from a packed EntityId (lower 32 bits).
    pub fn unpackIndex(entity_id: EntityId) u32 {
        return @truncate(entity_id.id);
    }

    /// Unpack the select id hash from a packed EntityId (upper 32 bits).
    /// Returns 0 if no hash was packed (forIndex was used instead of forIndexAndClose).
    pub fn unpackIdHash(entity_id: EntityId) u32 {
        return @truncate(entity_id.id >> 32);
    }
};

/// Re-exported from `entity.zig` — single canonical definition.
pub const typeId = entity_mod.typeId;

// =============================================================================
// Argument Packing (for updateWith/commandWith)
// =============================================================================

/// Pack an argument into an EntityId for transport through the handler system.
///
/// Arguments must fit in 8 bytes (u64). For larger data, use a pointer or index.
pub fn packArg(comptime Arg: type, arg: Arg) EntityId {
    comptime {
        std.debug.assert(@sizeOf(Arg) <= @sizeOf(u64));
    }
    var storage: u64 = 0;
    const arg_bytes = std.mem.asBytes(&arg);
    @memcpy(std.mem.asBytes(&storage)[0..@sizeOf(Arg)], arg_bytes);
    return .{ .id = storage };
}

/// Unpack an argument from an EntityId.
pub fn unpackArg(comptime Arg: type, entity_id: EntityId) Arg {
    var result: Arg = undefined;
    const id_bytes = std.mem.asBytes(&entity_id.id);
    @memcpy(std.mem.asBytes(&result), id_bytes[0..@sizeOf(Arg)]);
    return result;
}

// =============================================================================
// Tests
// =============================================================================

test "typeId returns consistent values" {
    const TestA = struct { a: i32 };
    const TestB = struct { b: i32 };

    const id_a1 = typeId(TestA);
    const id_a2 = typeId(TestA);
    const id_b = typeId(TestB);

    try std.testing.expectEqual(id_a1, id_a2);
    try std.testing.expect(id_a1 != id_b);
}

test "packArg/unpackArg roundtrip" {
    // Test enum
    const Page = enum { home, settings, about };
    const page_id = packArg(Page, .settings);
    const unpacked_page = unpackArg(Page, page_id);
    try std.testing.expectEqual(Page.settings, unpacked_page);

    // Test i32
    const int_id = packArg(i32, 42);
    const unpacked_int = unpackArg(i32, int_id);
    try std.testing.expectEqual(@as(i32, 42), unpacked_int);

    // Test negative i32
    const neg_id = packArg(i32, -999);
    const unpacked_neg = unpackArg(i32, neg_id);
    try std.testing.expectEqual(@as(i32, -999), unpacked_neg);

    // Test struct that fits in 8 bytes
    const Point = struct { x: i16, y: i16 };
    const point_id = packArg(Point, .{ .x = 100, .y = 200 });
    const unpacked_point = unpackArg(Point, point_id);
    try std.testing.expectEqual(@as(i16, 100), unpacked_point.x);
    try std.testing.expectEqual(@as(i16, 200), unpacked_point.y);

    // Test usize (index)
    const idx_id = packArg(usize, 12345);
    const unpacked_idx = unpackArg(usize, idx_id);
    try std.testing.expectEqual(@as(usize, 12345), unpacked_idx);

    // Test bool
    const bool_id = packArg(bool, true);
    const unpacked_bool = unpackArg(bool, bool_id);
    try std.testing.expectEqual(true, unpacked_bool);

    // Test u8
    const u8_id = packArg(u8, 255);
    const unpacked_u8 = unpackArg(u8, u8_id);
    try std.testing.expectEqual(@as(u8, 255), unpacked_u8);
}

test "packArg/unpackArg with zero values" {
    const zero_int = packArg(i32, 0);
    try std.testing.expectEqual(@as(i32, 0), unpackArg(i32, zero_int));

    const zero_usize = packArg(usize, 0);
    try std.testing.expectEqual(@as(usize, 0), unpackArg(usize, zero_usize));

    const false_bool = packArg(bool, false);
    try std.testing.expectEqual(false, unpackArg(bool, false_bool));
}
