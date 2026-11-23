const std = @import("std");
const bridge_mod = @import("bridge.zig");
const types = @import("types.zig");
const tree_mod = @import("tree.zig");
const snapshot_mod = @import("windows_snapshot.zig");
const provider_mod = @import("windows_provider.zig");
const reservation = @import("../core/reservation.zig");
const limits = @import("../core/limits.zig");
const uia = @import("../platform/windows/uia.zig");
const win32 = @import("../platform/windows/win32.zig");
const shell = @import("../platform/windows/shell.zig");

const assert = std.debug.assert;
const Fingerprint = tree_mod.Fingerprint;
const Server = provider_mod.Server;
const Provider = provider_mod.Provider;
const ChangeList = snapshot_mod.ChangeList;

const announcement_bytes_max: u16 = provider_mod.bstr_bytes_max;

const announcement_activity_id = "Gooey.Announcement";

pub const WindowsBridge = struct {
    host: ?*uia.Host,
    server: ?*Server,
    com_entered: bool,
    changes: ChangeList,

    const Self = @This();

    pub fn init(element_count_max: u16, host: ?*uia.Host) Self {
        assert(element_count_max > 0);
        var self: Self = .{ .host = host, .server = null, .com_entered = false, .changes = .{} };
        const window_host = host orelse return self;
        const hwnd = window_host.hwnd orelse return self;
        assert(window_host.root == null);

        self.com_entered = comEnter();
        const storage = reservation.reserve(Server, 1) catch {
            std.log.err("accessibility: UI Automation storage reservation failed", .{});
            return self;
        };
        storage[0].initInPlace(hwnd, element_count_max) catch {
            reservation.release(Server, storage, 1);
            std.log.err("accessibility: UI Automation storage reservation failed", .{});
            return self;
        };
        self.server = &storage[0];
        window_host.root = storage[0].root.simpleInterface();
        assert(self.server.?.alive);
        return self;
    }

    pub fn bridge(self: *Self) bridge_mod.Bridge {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = bridge_mod.Bridge.VTable{
        .syncDirty = syncDirty,
        .removeElements = removeElements,
        .announce = announce,
        .focusChanged = focusChanged,
        .isActive = isActive,
        .deinit = deinit,
    };

    fn castSelf(ptr: *anyopaque) *Self {
        return @ptrCast(@alignCast(ptr));
    }

    fn syncDirty(ptr: *anyopaque, tree: *const tree_mod.Tree, dirty: []const u16) void {
        const self = castSelf(ptr);
        const server = self.server orelse return;
        assert(dirty.len <= tree.count());
        assert(self.changes.change_count == 0);

        server.lockExclusive();
        server.snapshot.collectChanges(tree, dirty, &self.changes);
        server.snapshot.rebuild(tree);
        server.unlockExclusive();

        defer self.changes = .{};
        if (self.changes.structure_changed or self.changes.overflowed) {
            raiseStructureChanged(server);
        }
        for (self.changes.items()) |change| raisePropertyChanged(server, change);
    }

    fn removeElements(ptr: *anyopaque, fingerprints: []const Fingerprint) void {
        const self = castSelf(ptr);
        const server = self.server orelse return;
        assert(fingerprints.len <= server.snapshot.entries.len);
        if (fingerprints.len == 0) return;
        raiseStructureChanged(server);
    }

    fn announce(ptr: *anyopaque, message: []const u8, live: types.Live) void {
        const self = castSelf(ptr);
        const server = self.server orelse return;
        assert(@backingInt(live) <= @backingInt(types.Live.assertive));
        if (live == .off) return;

        const length = snapshot_mod.utf8PrefixLength(message, announcement_bytes_max);
        assert(length <= message.len);
        const display = provider_mod.bstrFromUtf8(message[0..length]) catch |err| {
            std.log.warn("accessibility: announcement dropped: {s}", .{@errorName(err)});
            return;
        };
        defer uia.SysFreeString(display);

        const activity = provider_mod.bstrFromUtf8(announcement_activity_id) catch |err| {
            std.log.warn("accessibility: announcement dropped: {s}", .{@errorName(err)});
            return;
        };
        defer uia.SysFreeString(activity);

        const processing = switch (live) {
            .assertive => uia.NotificationProcessing_ImportantAll,
            .polite => uia.NotificationProcessing_All,
            .off => unreachable,
        };
        const result = uia.UiaRaiseNotificationEvent(
            server.root.simpleInterface(),
            uia.NotificationKind_Other,
            processing,
            display,
            activity,
        );
        logFailure("UiaRaiseNotificationEvent", result);
    }

    fn focusChanged(ptr: *anyopaque, tree: *const tree_mod.Tree, index: ?u16) void {
        const self = castSelf(ptr);
        const server = self.server orelse return;
        assert(index == null or index.? < tree.count());
        const focused = index orelse return;
        const fingerprint = tree.getElement(focused).?.fingerprint;

        server.lockExclusive();
        const provider = claimIfPresent(server, fingerprint);
        server.unlockExclusive();

        const element = provider orelse return;
        defer _ = element.release();
        const event_id = uia.UIA_AutomationFocusChangedEventId;
        const result = uia.UiaRaiseAutomationEvent(element.simpleInterface(), event_id);
        logFailure("UiaRaiseAutomationEvent", result);
    }

    fn isActive(ptr: *anyopaque) bool {
        const self = castSelf(ptr);
        if (self.server == null) return false;
        const window_host = self.host.?;
        assert(window_host.root != null);
        if (window_host.client_requested) return true;
        return uia.UiaClientsAreListening() != win32.FALSE;
    }

    fn deinit(ptr: *anyopaque) void {
        const self = castSelf(ptr);
        defer if (self.com_entered) shell.CoUninitialize();
        const server = self.server orelse return;
        const window_host = self.host.?;
        assert(window_host.root == server.root.simpleInterface());

        window_host.root = null;
        _ = uia.UiaReturnRawElementProvider(server.hwnd, 0, 0, null);
        self.server = null;
        if (server.shutdown()) {
            server.deinit();
            reservation.release(Server, @as(*[1]Server, server), 1);
        } else {
            std.log.warn("accessibility: a UI Automation provider outlived its window", .{});
        }
    }
};

fn claimIfPresent(server: *Server, fingerprint: Fingerprint) ?*Provider {
    assert(fingerprint.isValid());
    assert(server.locked);
    _ = server.snapshot.find(fingerprint) orelse return null;
    return server.claim(fingerprint);
}

fn raisePropertyChanged(server: *Server, change: snapshot_mod.Change) void {
    assert(change.fingerprint.isValid());
    const property_id = provider_mod.propertyId(change.property);
    var value = uia.VARIANT.empty;

    server.lockExclusive();
    const provider = claimIfPresent(server, change.fingerprint);
    if (provider != null) {
        const index = server.snapshot.find(change.fingerprint).?;
        const entry = server.snapshot.entry(index);
        const snapshot = &server.snapshot;
        value = provider_mod.elementProperty(snapshot, entry, property_id) catch |err| blk: {
            std.log.warn(
                "accessibility: property {d} change raised without its value: {s}",
                .{ property_id, @errorName(err) },
            );
            break :blk uia.VARIANT.empty;
        };
    }
    server.unlockExclusive();

    const element = provider orelse return;
    defer _ = element.release();
    defer provider_mod.variantFree(&value);
    const result = uia.UiaRaiseAutomationPropertyChangedEvent(
        element.simpleInterface(),
        property_id,
        uia.VARIANT.empty,
        value,
    );
    logFailure("UiaRaiseAutomationPropertyChangedEvent", result);
}

fn raiseStructureChanged(server: *Server) void {
    assert(server.alive);
    const result = uia.UiaRaiseStructureChangedEvent(
        server.root.simpleInterface(),
        uia.StructureChangeType_ChildrenInvalidated,
        null,
        0,
    );
    logFailure("UiaRaiseStructureChangedEvent", result);
}

fn logFailure(comptime function: []const u8, result: uia.HRESULT) void {
    if (uia.succeeded(result)) return;
    std.log.debug("accessibility: " ++ function ++ " failed (HRESULT 0x{X:0>8})", .{
        @as(u32, @bitCast(result)),
    });
}

fn comEnter() bool {
    const result = shell.CoInitializeEx(
        null,
        shell.COINIT_APARTMENTTHREADED | shell.COINIT_DISABLE_OLE1DDE,
    );
    if (shell.succeeded(result)) {
        assert(result == shell.S_OK or result == shell.S_FALSE);
        return true;
    }
    if (result != shell.RPC_E_CHANGED_MODE) {
        std.log.warn("accessibility: CoInitializeEx failed (HRESULT 0x{X:0>8})", .{
            @as(u32, @bitCast(result)),
        });
    }
    return false;
}

comptime {
    assert(announcement_bytes_max <= provider_mod.bstr_bytes_max);
}

const testing = std.testing;

test "an inert bridge without a window is safe to drive" {
    var inert = WindowsBridge.init(tree_mod.Capacity.standard.element_count_max, null);
    const b = inert.bridge();
    defer b.deinit();

    const tree = try testing.allocator.create(tree_mod.Tree);
    defer testing.allocator.destroy(tree);
    try tree.initInPlace(&tree_mod.Capacity.standard);
    defer tree.deinit();
    tree.beginFrame();
    _ = tree.pushElement(.{ .role = .button, .name = "Test", .state = .{ .focused = true } });
    tree.popElement();
    tree.announce("Saved", .polite);
    tree.endFrame();

    try testing.expect(!b.isActive());
    b.syncDirty(tree, tree.getDirtyElements());
    b.removeElements(tree.getRemovedFingerprints());
    b.announce("Saved", .polite);
    b.focusChanged(tree, tree.getFocusedIndex());
    try testing.expectEqual(@as(?*Server, null), inert.server);
}

test "a bridge on a real window publishes its root, syncs, and tears down cleanly" {
    const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const instance = win32.GetModuleHandleW(null).?;
    const hwnd = win32.CreateWindowExW(
        0,
        class,
        class,
        0,
        0,
        0,
        200,
        100,
        null,
        null,
        instance,
        null,
    ).?;
    defer _ = win32.DestroyWindow(hwnd);

    var host: uia.Host = .{ .hwnd = hwnd };
    var windows_bridge = WindowsBridge.init(tree_mod.Capacity.standard.element_count_max, &host);
    const b = windows_bridge.bridge();
    try testing.expect(host.root != null);
    try testing.expect(windows_bridge.server != null);
    host.client_requested = true;
    try testing.expect(b.isActive());

    const tree = try testing.allocator.create(tree_mod.Tree);
    defer testing.allocator.destroy(tree);
    try tree.initInPlace(&tree_mod.Capacity.standard);
    defer tree.deinit();
    for ([_]bool{ true, false }) |with_second| {
        tree.beginFrame();
        _ = tree.pushElement(.{ .role = .checkbox, .name = "One", .state = .{ .focused = true } });
        tree.popElement();
        if (with_second) {
            _ = tree.pushElement(.{ .role = .button, .name = "Two" });
            tree.popElement();
        }
        tree.announce("Changed", .assertive);
        tree.endFrame();
        b.syncFrame(tree);
        try testing.expectEqual(tree.count(), windows_bridge.server.?.snapshot.entry_count);
        try testing.expectEqual(@as(u16, 0), windows_bridge.server.?.live_count);
    }

    b.deinit();
    try testing.expectEqual(@as(?*uia.IRawElementProviderSimple, null), host.root);
    try testing.expectEqual(@as(?*Server, null), windows_bridge.server);
}
