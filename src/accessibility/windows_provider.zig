//! UI Automation providers for the Windows accessibility bridge.
//!
//! A `Provider` is the COM object UI Automation holds for one element. It
//! names its element by fingerprint, never by snapshot index, so a reference a
//! client kept across frames keeps meaning the same element, and reports
//! `UIA_E_ELEMENTNOTAVAILABLE` once that element is gone. Every query reads
//! the bridge's `Snapshot` under the server's lock.
//!
//! ## Threading
//!
//! Providers report `ProviderOptions_UseComThreading`, and the bridge enters a
//! single-threaded apartment on the window's thread, so UI Automation calls
//! arrive through that thread's message loop. If the thread was already a
//! multithreaded apartment, calls arrive on COM threads instead. The lock
//! makes both cases correct: every provider method holds it while reading the
//! snapshot, and the bridge holds it while rebuilding. Nothing calls into UI
//! Automation while holding it, because an event raise may call straight back
//! into a provider on the same thread and the lock is not reentrant.
//!
//! ## Provider pool (CLAUDE.md §2, §7)
//!
//! `provider_count_max` objects of 96 B, 384 KiB, reserved at init and
//! resident only up to the high-water mark. A provider is claimed with one
//! reference whenever a method hands one out and returns to the free list when
//! its last reference is released. UI Automation identifies elements by
//! runtime id, not by object, so one element may have several live providers.
//!
//! Actions are not exposed: the accessibility tree has no path back to the
//! widgets, so `Invoke`, `SetValue`, `Toggle`, `SetFocus`, and similar return
//! `UIA_E_NOTSUPPORTED`. Screen readers fall back to keyboard and pointer
//! input, which the widgets handle.

const std = @import("std");
const constants = @import("constants.zig");
const types = @import("types.zig");
const tree_mod = @import("tree.zig");
const snapshot_mod = @import("windows_snapshot.zig");
const reservation = @import("../core/reservation.zig");
const layout = @import("../layout/layout.zig");
const uia = @import("../platform/windows/uia.zig");
const win32 = @import("../platform/windows/win32.zig");

const assert = std.debug.assert;
const Fingerprint = tree_mod.Fingerprint;
const Snapshot = snapshot_mod.Snapshot;
const Entry = snapshot_mod.Entry;
const HRESULT = uia.HRESULT;
const index_none = snapshot_mod.index_none;

const Simple = uia.IRawElementProviderSimple;
const Fragment = uia.IRawElementProviderFragment;
const FragmentRoot = uia.IRawElementProviderFragmentRoot;

/// Two providers per element: room for a client to cache every element of a
/// full tree while it navigates to fresh ones.
pub const provider_count_max: u16 = 2 * constants.MAX_ELEMENTS;

/// The longest UTF-8 string turned into a `BSTR`: the snapshot's largest text
/// cap, and the bridge's announcement cap.
pub const bstr_bytes_max: u16 = 1024;

const framework_id = "Gooey";

// =============================================================================
// Server
// =============================================================================

/// Everything a provider method may touch: the lock, the snapshot, and the
/// pool. Reserved by the bridge at init; providers point here.
pub const Server = struct {
    lock: uia.SRWLOCK,
    hwnd: win32.HWND,
    /// False once the bridge has shut down. Later calls report the element
    /// gone instead of reading the snapshot.
    alive: bool,
    exhaustion_logged: bool,
    snapshot: Snapshot,
    root: Provider,
    providers: []Provider,
    provider_high_water: u16,
    free_head: u16,
    live_count: u16,

    const Self = @This();

    pub fn initInPlace(self: *Self, hwnd: win32.HWND) error{OutOfMemory}!void {
        try self.snapshot.initInPlace();
        errdefer self.snapshot.deinit();

        self.providers = try reservation.reserve(Provider, provider_count_max);
        errdefer reservation.release(Provider, self.providers, 0);

        self.lock = .{};
        self.hwnd = hwnd;
        self.alive = true;
        self.exhaustion_logged = false;
        self.provider_high_water = 0;
        self.free_head = index_none;
        self.live_count = 0;
        // The root's first reference belongs to the bridge.
        self.root.initIn(self, .root, Fingerprint.INVALID);
        assert(self.root.reference_count.load(.monotonic) == 1);
        assert(self.providers.len == provider_count_max);
    }

    /// Free the storage. Only after `shutdown` reported every provider released.
    pub fn deinit(self: *Self) void {
        assert(!self.alive);
        assert(self.live_count == 0);
        reservation.release(Provider, self.providers, self.provider_high_water);
        self.snapshot.deinit();
        self.providers = &.{};
    }

    pub fn lockExclusive(self: *Self) void {
        uia.AcquireSRWLockExclusive(&self.lock);
    }

    pub fn unlockExclusive(self: *Self) void {
        uia.ReleaseSRWLockExclusive(&self.lock);
    }

    /// Stop serving, ask UI Automation to drop its references, and release the
    /// bridge's own reference to the root. Returns whether every provider is
    /// now released, which is what makes freeing the storage safe.
    pub fn shutdown(self: *Self) bool {
        self.lockExclusive();
        self.alive = false;
        const high_water = self.provider_high_water;
        self.unlockExclusive();

        // Outside the lock: a disconnect releases references, and the last
        // release takes the lock to reclaim its slot.
        _ = uia.UiaDisconnectProvider(self.root.simpleInterface());
        var slot: u16 = 0;
        while (slot < high_water) : (slot += 1) {
            const provider = &self.providers[slot];
            if (provider.reference_count.load(.acquire) == 0) continue;
            // Fails harmlessly for a provider no client holds.
            _ = uia.UiaDisconnectProvider(provider.simpleInterface());
        }
        _ = self.root.release();

        self.lockExclusive();
        defer self.unlockExclusive();
        return self.live_count == 0 and self.root.reference_count.load(.acquire) == 0;
    }

    /// Claim a provider for the element with `fingerprint`, holding one
    /// reference for the caller. The lock must be held.
    pub fn claim(self: *Self, fingerprint: Fingerprint) ?*Provider {
        assert(fingerprint.isValid());
        assert(self.live_count <= self.provider_high_water);
        const slot = self.claimSlot() orelse {
            self.reportExhaustion();
            return null;
        };
        const provider = &self.providers[slot];
        provider.initIn(self, .element, fingerprint);
        self.live_count += 1;
        assert(self.live_count <= provider_count_max);
        return provider;
    }

    fn claimSlot(self: *Self) ?u16 {
        if (self.free_head != index_none) {
            const slot = self.free_head;
            assert(self.providers[slot].kind == .free);
            self.free_head = self.providers[slot].next_free;
            return slot;
        }
        if (self.provider_high_water < provider_count_max) {
            const slot = self.provider_high_water;
            self.provider_high_water += 1;
            return slot;
        }
        return null;
    }

    /// Return a provider whose last reference was released. Lock held.
    fn reclaim(self: *Self, provider: *Provider) void {
        assert(provider.kind == .element);
        assert(provider.reference_count.load(.acquire) == 0);
        const offset = @intFromPtr(provider) - @intFromPtr(self.providers.ptr);
        const slot: u16 = @intCast(@divExact(offset, @sizeOf(Provider)));
        assert(slot < self.provider_high_water);
        provider.kind = .free;
        provider.next_free = self.free_head;
        self.free_head = slot;
        self.live_count -= 1;
    }

    /// Exhaustion is the one capacity error here that does not stop the
    /// process, against CLAUDE.md §2's fail-fast rule. Demand comes from
    /// another process: a screen reader decides how many element references
    /// it holds, and it must not be able to crash the application. The call
    /// that needed a provider returns `E_OUTOFMEMORY` to that client instead.
    /// Logged once per window, at the level the backend uses for other
    /// requests it refuses.
    fn reportExhaustion(self: *Self) void {
        if (self.exhaustion_logged) return;
        self.exhaustion_logged = true;
        std.log.warn(
            "accessibility: UI Automation provider pool exhausted " ++
                "(capacity {d}, requested 1, live {d})",
            .{ provider_count_max, self.live_count },
        );
    }
};

// =============================================================================
// Provider
// =============================================================================

pub const Provider = struct {
    // One vtable pointer per interface. An interface pointer is the address
    // of its field, and `providerFrom` recovers the object from it.
    simple: *const Simple.VTable,
    fragment: *const Fragment.VTable,
    fragment_root: *const FragmentRoot.VTable,
    value: *const uia.IValueProvider.VTable,
    range_value: *const uia.IRangeValueProvider.VTable,
    toggle: *const uia.IToggleProvider.VTable,
    expand_collapse: *const uia.IExpandCollapseProvider.VTable,
    selection_item: *const uia.ISelectionItemProvider.VTable,
    reference_count: std.atomic.Value(u32),
    fingerprint: Fingerprint,
    server: *Server,
    next_free: u16,
    kind: Kind,

    pub const Kind = enum(u8) { root, element, free };

    fn initIn(self: *Provider, server: *Server, kind: Kind, fingerprint: Fingerprint) void {
        assert(kind != .free);
        if (kind == .element) assert(fingerprint.isValid());
        self.* = .{
            .simple = &simple_vtable,
            .fragment = &fragment_vtable,
            .fragment_root = &fragment_root_vtable,
            .value = &value_vtable,
            .range_value = &range_value_vtable,
            .toggle = &toggle_vtable,
            .expand_collapse = &expand_collapse_vtable,
            .selection_item = &selection_item_vtable,
            .reference_count = .init(1),
            .fingerprint = fingerprint,
            .server = server,
            .next_free = index_none,
            .kind = kind,
        };
    }

    pub fn simpleInterface(self: *Provider) *Simple {
        return @ptrCast(&self.simple);
    }

    pub fn fragmentInterface(self: *Provider) *Fragment {
        return @ptrCast(&self.fragment);
    }

    fn elementRole(self: *const Provider) types.Role {
        assert(self.kind == .element);
        assert(self.fingerprint.isValid());
        return @fromBackingInt(@intCast(self.fingerprint.role));
    }

    pub fn addRef(self: *Provider) u32 {
        assert(self.kind != .free);
        const previous = self.reference_count.fetchAdd(1, .monotonic);
        assert(previous > 0); // No reference can exist to add to.
        return previous + 1;
    }

    pub fn release(self: *Provider) u32 {
        assert(self.kind != .free);
        const previous = self.reference_count.fetchSub(1, .acq_rel);
        assert(previous > 0);
        // The root's storage belongs to the server and is never reclaimed.
        if (previous == 1 and self.kind == .element) {
            const server = self.server;
            server.lockExclusive();
            defer server.unlockExclusive();
            server.reclaim(self);
        }
        return previous - 1;
    }

    /// The element's snapshot index with the lock held, or null with the lock
    /// released when the element is gone or the bridge has shut down.
    fn lockIndex(self: *Provider) ?u16 {
        assert(self.kind == .element);
        const server = self.server;
        server.lockExclusive();
        if (server.alive) {
            if (server.snapshot.find(self.fingerprint)) |index| return index;
        }
        server.unlockExclusive();
        return null;
    }

    /// The root's counterpart of `lockIndex`: true with the lock held.
    fn lockRoot(self: *Provider) bool {
        assert(self.kind == .root);
        const server = self.server;
        server.lockExclusive();
        if (server.alive) return true;
        server.unlockExclusive();
        return false;
    }

    fn queryInterface(self: *Provider, iid: ?*const uia.GUID, out: ?*?*anyopaque) HRESULT {
        const target = out orelse return uia.E_POINTER;
        target.* = null;
        const requested = iid orelse return uia.E_POINTER;
        const interface = self.interfaceFor(requested) orelse return uia.E_NOINTERFACE;
        _ = self.addRef();
        target.* = interface;
        return uia.S_OK;
    }

    fn interfaceFor(self: *Provider, iid: *const uia.GUID) ?*anyopaque {
        if (uia.guidEql(iid, &uia.IID_IUnknown)) return @ptrCast(&self.simple);
        if (uia.guidEql(iid, &uia.IID_IRawElementProviderSimple)) return @ptrCast(&self.simple);
        if (uia.guidEql(iid, &uia.IID_IRawElementProviderFragment)) return @ptrCast(&self.fragment);
        if (self.kind == .root) {
            if (uia.guidEql(iid, &uia.IID_IRawElementProviderFragmentRoot)) {
                return @ptrCast(&self.fragment_root);
            }
            return null;
        }
        return self.patternInterface(patternIdFromIid(iid) orelse return null);
    }

    /// The pattern interface for `pattern_id`, or null when the element's role
    /// does not support it. Fixed per role, as COM identity requires.
    fn patternInterface(self: *Provider, pattern_id: i32) ?*anyopaque {
        if (self.kind != .element) return null;
        const role = self.elementRole();
        switch (pattern_id) {
            uia.UIA_ValuePatternId => if (snapshot_mod.supportsValue(role)) {
                return @ptrCast(&self.value);
            },
            uia.UIA_RangeValuePatternId => if (snapshot_mod.supportsRangeValue(role)) {
                return @ptrCast(&self.range_value);
            },
            uia.UIA_TogglePatternId => if (snapshot_mod.supportsToggle(role)) {
                return @ptrCast(&self.toggle);
            },
            uia.UIA_ExpandCollapsePatternId => if (snapshot_mod.supportsExpandCollapse(role)) {
                return @ptrCast(&self.expand_collapse);
            },
            uia.UIA_SelectionItemPatternId => if (snapshot_mod.supportsSelectionItem(role)) {
                return @ptrCast(&self.selection_item);
            },
            else => {},
        }
        return null;
    }
};

fn patternIdFromIid(iid: *const uia.GUID) ?i32 {
    if (uia.guidEql(iid, &uia.IID_IValueProvider)) return uia.UIA_ValuePatternId;
    if (uia.guidEql(iid, &uia.IID_IRangeValueProvider)) return uia.UIA_RangeValuePatternId;
    if (uia.guidEql(iid, &uia.IID_IToggleProvider)) return uia.UIA_TogglePatternId;
    if (uia.guidEql(iid, &uia.IID_IExpandCollapseProvider)) return uia.UIA_ExpandCollapsePatternId;
    if (uia.guidEql(iid, &uia.IID_ISelectionItemProvider)) return uia.UIA_SelectionItemPatternId;
    return null;
}

/// Recover the provider from one of its interface pointers.
fn providerFrom(comptime field: []const u8, interface: anytype) *Provider {
    const field_pointer: *@FieldType(Provider, field) = @ptrCast(@alignCast(interface));
    const provider: *Provider = @fieldParentPtr(field, field_pointer);
    assert(provider.kind != .free);
    return provider;
}

/// Hand out a provider for the element at `index`, or nothing for
/// `index_none`. The lock must be held.
fn claimInto(server: *Server, index: u16, target: *?*Fragment) HRESULT {
    assert(target.* == null);
    if (index == index_none) return uia.S_OK;
    const fingerprint = server.snapshot.entry(index).fingerprint;
    const provider = server.claim(fingerprint) orelse return uia.E_OUTOFMEMORY;
    target.* = provider.fragmentInterface();
    return uia.S_OK;
}

// =============================================================================
// IUnknown
// =============================================================================

fn Unknown(comptime field: []const u8, comptime Interface: type) type {
    return struct {
        fn queryInterface(
            this: *Interface,
            iid: ?*const uia.GUID,
            out: ?*?*anyopaque,
        ) callconv(.winapi) HRESULT {
            return providerFrom(field, this).queryInterface(iid, out);
        }

        fn addRef(this: *Interface) callconv(.winapi) u32 {
            return providerFrom(field, this).addRef();
        }

        fn release(this: *Interface) callconv(.winapi) u32 {
            return providerFrom(field, this).release();
        }
    };
}

fn NotSupported(comptime Interface: type) type {
    return struct {
        fn call(_: *Interface) callconv(.winapi) HRESULT {
            return uia.UIA_E_NOTSUPPORTED;
        }
    };
}

// =============================================================================
// IRawElementProviderSimple
// =============================================================================

fn simpleProviderOptions(_: *Simple, out: ?*i32) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = uia.ProviderOptions_ServerSideProvider | uia.ProviderOptions_UseComThreading;
    return uia.S_OK;
}

fn simplePatternProvider(
    this: *Simple,
    pattern_id: i32,
    out: ?*?*anyopaque,
) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    const provider = providerFrom("simple", this);
    target.* = provider.patternInterface(pattern_id);
    if (target.* != null) _ = provider.addRef();
    return uia.S_OK;
}

fn simplePropertyValue(
    this: *Simple,
    property_id: i32,
    out: ?*uia.VARIANT,
) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = uia.VARIANT.empty;
    const provider = providerFrom("simple", this);
    // The host window supplies the root's properties.
    if (provider.kind == .root) return uia.S_OK;
    const index = provider.lockIndex() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
    defer provider.server.unlockExclusive();
    const snapshot = &provider.server.snapshot;
    target.* = elementProperty(snapshot, snapshot.entry(index), property_id) catch
        return uia.E_OUTOFMEMORY;
    return uia.S_OK;
}

fn simpleHostProvider(this: *Simple, out: ?*?*Simple) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    const provider = providerFrom("simple", this);
    if (provider.kind != .root) return uia.S_OK;
    // `hwnd` never changes after init, so this needs no lock.
    return uia.UiaHostProviderFromHwnd(provider.server.hwnd, target);
}

const simple_vtable: Simple.VTable = .{
    .QueryInterface = Unknown("simple", Simple).queryInterface,
    .AddRef = Unknown("simple", Simple).addRef,
    .Release = Unknown("simple", Simple).release,
    .get_ProviderOptions = simpleProviderOptions,
    .GetPatternProvider = simplePatternProvider,
    .GetPropertyValue = simplePropertyValue,
    .get_HostRawElementProvider = simpleHostProvider,
};

// =============================================================================
// IRawElementProviderFragment
// =============================================================================

fn fragmentNavigate(this: *Fragment, direction: i32, out: ?*?*Fragment) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    if (direction < uia.NavigateDirection_Parent) return uia.E_INVALIDARG;
    if (direction > uia.NavigateDirection_LastChild) return uia.E_INVALIDARG;
    const provider = providerFrom("fragment", this);
    return switch (provider.kind) {
        .root => navigateRoot(provider, direction, target),
        .element => navigateElement(provider, direction, target),
        .free => unreachable, // `providerFrom` asserts a live provider.
    };
}

fn navigateRoot(root: *Provider, direction: i32, target: *?*Fragment) HRESULT {
    if (!root.lockRoot()) return uia.UIA_E_ELEMENTNOTAVAILABLE;
    const server = root.server;
    defer server.unlockExclusive();
    const index = switch (direction) {
        uia.NavigateDirection_FirstChild => server.snapshot.root_first_child,
        uia.NavigateDirection_LastChild => server.snapshot.root_last_child,
        // The host window owns the root's parent and siblings.
        else => return uia.S_OK,
    };
    return claimInto(server, index, target);
}

fn navigateElement(provider: *Provider, direction: i32, target: *?*Fragment) HRESULT {
    const index = provider.lockIndex() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
    const server = provider.server;
    defer server.unlockExclusive();
    const entry = server.snapshot.entry(index);
    const target_index = switch (direction) {
        uia.NavigateDirection_Parent => entry.parent,
        uia.NavigateDirection_NextSibling => entry.next_sibling,
        uia.NavigateDirection_PreviousSibling => entry.previous_sibling,
        uia.NavigateDirection_FirstChild => entry.first_child,
        uia.NavigateDirection_LastChild => entry.last_child,
        else => unreachable, // Range-checked by `fragmentNavigate`.
    };
    if (direction == uia.NavigateDirection_Parent and target_index == index_none) {
        _ = server.root.addRef();
        target.* = server.root.fragmentInterface();
        return uia.S_OK;
    }
    return claimInto(server, target_index, target);
}

fn fragmentRuntimeId(this: *Fragment, out: ?*?*uia.SAFEARRAY) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    const provider = providerFrom("fragment", this);
    // The host window supplies the root's runtime id.
    if (provider.kind == .root) return uia.S_OK;
    const ids = runtimeId(provider.fingerprint);
    target.* = runtimeIdArray(&ids) orelse return uia.E_OUTOFMEMORY;
    return uia.S_OK;
}

fn fragmentBoundingRectangle(this: *Fragment, out: ?*uia.UiaRect) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = uia.UiaRect.empty;
    const provider = providerFrom("fragment", this);
    // The host window supplies the root's rectangle.
    if (provider.kind == .root) return uia.S_OK;
    const index = provider.lockIndex() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
    const server = provider.server;
    defer server.unlockExclusive();
    const entry = server.snapshot.entry(index);
    if (entry.isExposed()) target.* = screenRect(server.hwnd, entry.bounds);
    return uia.S_OK;
}

fn fragmentEmbeddedRoots(_: *Fragment, out: ?*?*uia.SAFEARRAY) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    return uia.S_OK;
}

fn fragmentRoot(this: *Fragment, out: ?*?*FragmentRoot) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    const root = &providerFrom("fragment", this).server.root;
    assert(root.kind == .root);
    _ = root.addRef();
    target.* = @ptrCast(&root.fragment_root);
    return uia.S_OK;
}

const fragment_vtable: Fragment.VTable = .{
    .QueryInterface = Unknown("fragment", Fragment).queryInterface,
    .AddRef = Unknown("fragment", Fragment).addRef,
    .Release = Unknown("fragment", Fragment).release,
    .Navigate = fragmentNavigate,
    .GetRuntimeId = fragmentRuntimeId,
    .get_BoundingRectangle = fragmentBoundingRectangle,
    .GetEmbeddedFragmentRoots = fragmentEmbeddedRoots,
    .SetFocus = NotSupported(Fragment).call,
    .get_FragmentRoot = fragmentRoot,
};

// =============================================================================
// IRawElementProviderFragmentRoot
// =============================================================================

fn rootElementFromPoint(
    this: *FragmentRoot,
    x: f64,
    y: f64,
    out: ?*?*Fragment,
) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    const root = providerFrom("fragment_root", this);
    const point = clientPoint(root.server.hwnd, x, y) orelse return uia.S_OK;
    if (!root.lockRoot()) return uia.UIA_E_ELEMENTNOTAVAILABLE;
    defer root.server.unlockExclusive();
    // No element under the point means the point is on the root itself.
    const index = root.server.snapshot.hitTest(point[0], point[1]) orelse return uia.S_OK;
    return claimInto(root.server, index, target);
}

fn rootFocus(this: *FragmentRoot, out: ?*?*Fragment) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    const root = providerFrom("fragment_root", this);
    if (!root.lockRoot()) return uia.UIA_E_ELEMENTNOTAVAILABLE;
    defer root.server.unlockExclusive();
    return claimInto(root.server, root.server.snapshot.focused, target);
}

const fragment_root_vtable: FragmentRoot.VTable = .{
    .QueryInterface = Unknown("fragment_root", FragmentRoot).queryInterface,
    .AddRef = Unknown("fragment_root", FragmentRoot).addRef,
    .Release = Unknown("fragment_root", FragmentRoot).release,
    .ElementProviderFromPoint = rootElementFromPoint,
    .GetFocus = rootFocus,
};

// =============================================================================
// Patterns
// =============================================================================

/// A pattern property getter: reads one value from the element's entry.
fn Getter(
    comptime field: []const u8,
    comptime Interface: type,
    comptime T: type,
    comptime read: fn (*const Snapshot, *const Entry) T,
) type {
    return struct {
        fn get(this: *Interface, out: ?*T) callconv(.winapi) HRESULT {
            const target = out orelse return uia.E_POINTER;
            const provider = providerFrom(field, this);
            const index = provider.lockIndex() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
            defer provider.server.unlockExclusive();
            const snapshot = &provider.server.snapshot;
            target.* = read(snapshot, snapshot.entry(index));
            return uia.S_OK;
        }
    };
}

fn valueSet(_: *uia.IValueProvider, _: ?win32.LPCWSTR) callconv(.winapi) HRESULT {
    return uia.UIA_E_NOTSUPPORTED;
}

fn valueGet(this: *uia.IValueProvider, out: ?*?uia.BSTR) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null;
    const provider = providerFrom("value", this);
    const index = provider.lockIndex() orelse return uia.UIA_E_ELEMENTNOTAVAILABLE;
    defer provider.server.unlockExclusive();
    const snapshot = &provider.server.snapshot;
    const text = snapshot.textOf(snapshot.entry(index).value);
    target.* = bstrFromUtf8(text) catch return uia.E_OUTOFMEMORY;
    return uia.S_OK;
}

fn readReadOnly(_: *const Snapshot, entry: *const Entry) win32.BOOL {
    return toBool(entry.state.readonly);
}

const value_vtable: uia.IValueProvider.VTable = .{
    .QueryInterface = Unknown("value", uia.IValueProvider).queryInterface,
    .AddRef = Unknown("value", uia.IValueProvider).addRef,
    .Release = Unknown("value", uia.IValueProvider).release,
    .SetValue = valueSet,
    .get_Value = valueGet,
    .get_IsReadOnly = Getter("value", uia.IValueProvider, win32.BOOL, readReadOnly).get,
};

fn rangeSet(_: *uia.IRangeValueProvider, _: f64) callconv(.winapi) HRESULT {
    return uia.UIA_E_NOTSUPPORTED;
}

fn readRangeValue(_: *const Snapshot, entry: *const Entry) f64 {
    return entry.value_now;
}

fn readRangeReadOnly(_: *const Snapshot, entry: *const Entry) win32.BOOL {
    return toBool(entry.state.readonly or entry.role == .progressbar);
}

fn readRangeMaximum(_: *const Snapshot, entry: *const Entry) f64 {
    return entry.value_max;
}

fn readRangeMinimum(_: *const Snapshot, entry: *const Entry) f64 {
    return entry.value_min;
}

/// UI Automation accepts NaN for a step size the control does not define.
fn readRangeStep(_: *const Snapshot, _: *const Entry) f64 {
    return std.math.nan(f64);
}

const RangeValue = uia.IRangeValueProvider;
const range_value_vtable: RangeValue.VTable = .{
    .QueryInterface = Unknown("range_value", RangeValue).queryInterface,
    .AddRef = Unknown("range_value", RangeValue).addRef,
    .Release = Unknown("range_value", RangeValue).release,
    .SetValue = rangeSet,
    .get_Value = Getter("range_value", RangeValue, f64, readRangeValue).get,
    .get_IsReadOnly = Getter("range_value", RangeValue, win32.BOOL, readRangeReadOnly).get,
    .get_Maximum = Getter("range_value", RangeValue, f64, readRangeMaximum).get,
    .get_Minimum = Getter("range_value", RangeValue, f64, readRangeMinimum).get,
    .get_LargeChange = Getter("range_value", RangeValue, f64, readRangeStep).get,
    .get_SmallChange = Getter("range_value", RangeValue, f64, readRangeStep).get,
};

fn readToggleState(_: *const Snapshot, entry: *const Entry) i32 {
    return toggleState(entry);
}

const Toggle = uia.IToggleProvider;
const toggle_vtable: Toggle.VTable = .{
    .QueryInterface = Unknown("toggle", Toggle).queryInterface,
    .AddRef = Unknown("toggle", Toggle).addRef,
    .Release = Unknown("toggle", Toggle).release,
    .Toggle = NotSupported(Toggle).call,
    .get_ToggleState = Getter("toggle", Toggle, i32, readToggleState).get,
};

fn readExpandCollapseState(_: *const Snapshot, entry: *const Entry) i32 {
    return expandCollapseState(entry);
}

const ExpandCollapse = uia.IExpandCollapseProvider;
const expand_collapse_vtable: ExpandCollapse.VTable = .{
    .QueryInterface = Unknown("expand_collapse", ExpandCollapse).queryInterface,
    .AddRef = Unknown("expand_collapse", ExpandCollapse).addRef,
    .Release = Unknown("expand_collapse", ExpandCollapse).release,
    .Expand = NotSupported(ExpandCollapse).call,
    .Collapse = NotSupported(ExpandCollapse).call,
    .get_ExpandCollapseState = Getter(
        "expand_collapse",
        ExpandCollapse,
        i32,
        readExpandCollapseState,
    ).get,
};

fn readIsSelected(_: *const Snapshot, entry: *const Entry) win32.BOOL {
    return toBool(snapshot_mod.isSelected(entry.role, entry.state));
}

fn selectionContainer(_: *uia.ISelectionItemProvider, out: ?*?*Simple) callconv(.winapi) HRESULT {
    const target = out orelse return uia.E_POINTER;
    target.* = null; // The tree has no selection containers to point to.
    return uia.S_OK;
}

const SelectionItem = uia.ISelectionItemProvider;
const selection_item_vtable: SelectionItem.VTable = .{
    .QueryInterface = Unknown("selection_item", SelectionItem).queryInterface,
    .AddRef = Unknown("selection_item", SelectionItem).addRef,
    .Release = Unknown("selection_item", SelectionItem).release,
    .Select = NotSupported(SelectionItem).call,
    .AddToSelection = NotSupported(SelectionItem).call,
    .RemoveFromSelection = NotSupported(SelectionItem).call,
    .get_IsSelected = Getter("selection_item", SelectionItem, win32.BOOL, readIsSelected).get,
    .get_SelectionContainer = selectionContainer,
};

// =============================================================================
// Properties
// =============================================================================

/// The value of `property_id` for an element, or `VT_EMPTY` to let UI
/// Automation apply its default. A `BSTR` result is owned by the caller.
pub fn elementProperty(
    snapshot: *const Snapshot,
    entry: *const Entry,
    property_id: i32,
) error{OutOfMemory}!uia.VARIANT {
    assert(entry.fingerprint.isValid());
    const role = entry.role;
    return switch (property_id) {
        uia.UIA_ControlTypePropertyId => variantInt(role.toUiaControlType()),
        uia.UIA_NamePropertyId => try variantText(snapshot.textOf(entry.name)),
        uia.UIA_HelpTextPropertyId => try variantText(snapshot.textOf(entry.description)),
        uia.UIA_HasKeyboardFocusPropertyId => variantBool(entry.state.focused),
        uia.UIA_IsKeyboardFocusablePropertyId => variantBool(entry.isFocusable()),
        uia.UIA_IsEnabledPropertyId => variantBool(!entry.state.disabled),
        uia.UIA_IsControlElementPropertyId => variantBool(entry.isExposed()),
        uia.UIA_IsContentElementPropertyId => variantBool(entry.isExposed()),
        uia.UIA_IsOffscreenPropertyId => variantBool(entry.state.hidden),
        uia.UIA_FrameworkIdPropertyId => try variantText(framework_id),
        uia.UIA_IsRequiredForFormPropertyId => variantBool(entry.state.required),
        uia.UIA_AriaRolePropertyId => try variantText(role.toAriaRole()),
        uia.UIA_LiveSettingPropertyId => variantInt(liveSetting(entry)),
        uia.UIA_PositionInSetPropertyId => variantCount(entry.pos_in_set),
        uia.UIA_SizeOfSetPropertyId => variantCount(entry.set_size),
        uia.UIA_HeadingLevelPropertyId => variantInt(headingLevel(entry.heading_level)),
        uia.UIA_IsDialogPropertyId => variantBool(role == .dialog or role == .alertdialog),
        else => try patternProperty(snapshot, entry, property_id),
    };
}

/// Pattern properties, which change events carry as their new value.
fn patternProperty(
    snapshot: *const Snapshot,
    entry: *const Entry,
    property_id: i32,
) error{OutOfMemory}!uia.VARIANT {
    const role = entry.role;
    switch (property_id) {
        uia.UIA_ValueValuePropertyId => if (snapshot_mod.supportsValue(role)) {
            return variantText(snapshot.textOf(entry.value));
        },
        uia.UIA_RangeValueValuePropertyId => if (snapshot_mod.supportsRangeValue(role)) {
            return variantDouble(entry.value_now);
        },
        uia.UIA_ToggleToggleStatePropertyId => if (snapshot_mod.supportsToggle(role)) {
            return variantInt(toggleState(entry));
        },
        uia.UIA_ExpandCollapseExpandCollapseStatePropertyId => {
            if (snapshot_mod.supportsExpandCollapse(role)) {
                return variantInt(expandCollapseState(entry));
            }
        },
        uia.UIA_SelectionItemIsSelectedPropertyId => if (snapshot_mod.supportsSelectionItem(role)) {
            return variantBool(snapshot_mod.isSelected(role, entry.state));
        },
        else => {},
    }
    return uia.VARIANT.empty;
}

/// The property id a change event reports for `property`.
pub fn propertyId(property: snapshot_mod.Property) i32 {
    return switch (property) {
        .name => uia.UIA_NamePropertyId,
        .help_text => uia.UIA_HelpTextPropertyId,
        .value => uia.UIA_ValueValuePropertyId,
        .range_value => uia.UIA_RangeValueValuePropertyId,
        .toggle_state => uia.UIA_ToggleToggleStatePropertyId,
        .expand_collapse_state => uia.UIA_ExpandCollapseExpandCollapseStatePropertyId,
        .is_selected => uia.UIA_SelectionItemIsSelectedPropertyId,
        .is_enabled => uia.UIA_IsEnabledPropertyId,
    };
}

fn toggleState(entry: *const Entry) i32 {
    assert(snapshot_mod.supportsToggle(entry.role));
    return if (entry.state.checked) uia.ToggleState_On else uia.ToggleState_Off;
}

/// Expanded or collapsed when the element can open something; otherwise a
/// leaf, such as a tree item with no children.
fn expandCollapseState(entry: *const Entry) i32 {
    assert(snapshot_mod.supportsExpandCollapse(entry.role));
    if (entry.state.expanded) return uia.ExpandCollapseState_Expanded;
    const expandable = entry.role == .combobox or entry.state.has_popup or
        entry.first_child != index_none;
    if (expandable) return uia.ExpandCollapseState_Collapsed;
    return uia.ExpandCollapseState_LeafNode;
}

/// The element's live setting, with ARIA's defaults for alerts and status.
fn liveSetting(entry: *const Entry) i32 {
    const live: types.Live = if (entry.live != .off) entry.live else switch (entry.role) {
        .alert => .assertive,
        .status => .polite,
        else => .off,
    };
    return switch (live) {
        .off => uia.LiveSetting_Off,
        .polite => uia.LiveSetting_Polite,
        .assertive => uia.LiveSetting_Assertive,
    };
}

fn headingLevel(level: types.HeadingLevel) i32 {
    const number = level.toAriaLevel() orelse return uia.HeadingLevel_None;
    assert(number >= 1);
    assert(number <= 6);
    return uia.HeadingLevel1 + @as(i32, number) - 1;
}

/// `[UiaAppendRuntimeId, low, high]`: unique within the host window, which
/// UI Automation prefixes.
pub fn runtimeId(fingerprint: Fingerprint) [3]i32 {
    assert(fingerprint.isValid());
    const bits = fingerprint.toU64();
    return .{
        uia.UiaAppendRuntimeId,
        @bitCast(@as(u32, @truncate(bits))),
        @bitCast(@as(u32, @truncate(bits >> 32))),
    };
}

fn runtimeIdArray(ids: *const [3]i32) ?*uia.SAFEARRAY {
    assert(ids[0] == uia.UiaAppendRuntimeId);
    const array = uia.SafeArrayCreateVector(uia.VT_I4, 0, ids.len) orelse return null;
    for (ids, 0..) |id, position| {
        const index: i32 = @intCast(position);
        if (!uia.succeeded(uia.SafeArrayPutElement(array, &index, &id))) {
            _ = uia.SafeArrayDestroy(array);
            return null;
        }
    }
    return array;
}

// =============================================================================
// Values and coordinates
// =============================================================================

fn toBool(value: bool) win32.BOOL {
    return if (value) win32.TRUE else win32.FALSE;
}

fn variantInt(value: i32) uia.VARIANT {
    var variant = uia.VARIANT.empty;
    variant.vt = uia.VT_I4;
    variant.value.lVal = value;
    return variant;
}

fn variantDouble(value: f64) uia.VARIANT {
    var variant = uia.VARIANT.empty;
    variant.vt = uia.VT_R8;
    variant.value.dblVal = value;
    return variant;
}

fn variantBool(value: bool) uia.VARIANT {
    var variant = uia.VARIANT.empty;
    variant.vt = uia.VT_BOOL;
    variant.value.boolVal = if (value) uia.VARIANT_TRUE else uia.VARIANT_FALSE;
    return variant;
}

/// A set position or size; zero means the element is not in a set.
fn variantCount(count: u16) uia.VARIANT {
    if (count == 0) return uia.VARIANT.empty;
    return variantInt(count);
}

fn variantText(text: []const u8) error{OutOfMemory}!uia.VARIANT {
    var variant = uia.VARIANT.empty;
    variant.vt = uia.VT_BSTR;
    variant.value.bstrVal = try bstrFromUtf8(text);
    return variant;
}

/// Free what a `VARIANT` from `elementProperty` owns.
pub fn variantFree(variant: *uia.VARIANT) void {
    if (variant.vt == uia.VT_BSTR) uia.SysFreeString(variant.value.bstrVal);
    variant.* = uia.VARIANT.empty;
}

/// A `BSTR` holding `text`, which the caller (or COM) frees. Invalid UTF-8 is
/// a bug in the text's source; it is logged and exposed as empty.
pub fn bstrFromUtf8(text: []const u8) error{OutOfMemory}!uia.BSTR {
    assert(text.len <= bstr_bytes_max);
    var units: [bstr_bytes_max]u16 = undefined;
    const count = std.unicode.utf8ToUtf16Le(&units, text) catch blk: {
        std.log.warn("accessibility: text is not valid UTF-8; exposing it as empty", .{});
        break :blk 0;
    };
    assert(count <= text.len);
    return uia.SysAllocStringLen(&units, @intCast(count)) orelse error.OutOfMemory;
}

/// Device pixels per logical pixel, or null for a window that no longer exists.
fn windowScale(hwnd: win32.HWND) ?f64 {
    const dpi = win32.GetDpiForWindow(hwnd);
    if (dpi == 0) return null;
    const dpi_default: f64 = @floatFromInt(win32.USER_DEFAULT_SCREEN_DPI);
    return @as(f64, @floatFromInt(dpi)) / dpi_default;
}

/// The client area's top-left corner in screen pixels.
fn clientOrigin(hwnd: win32.HWND) ?win32.POINT {
    var origin: win32.POINT = .{ .x = 0, .y = 0 };
    if (win32.ClientToScreen(hwnd, &origin) == win32.FALSE) return null;
    return origin;
}

/// Logical client bounds to a screen rectangle in physical pixels. Read at
/// query time, so a window moved since the last frame reports correctly.
fn screenRect(hwnd: win32.HWND, bounds: layout.BoundingBox) uia.UiaRect {
    assert(bounds.width >= 0);
    assert(bounds.height >= 0);
    const scale = windowScale(hwnd) orelse return uia.UiaRect.empty;
    const origin = clientOrigin(hwnd) orelse return uia.UiaRect.empty;
    return .{
        .left = @as(f64, @floatFromInt(origin.x)) + bounds.x * scale,
        .top = @as(f64, @floatFromInt(origin.y)) + bounds.y * scale,
        .width = bounds.width * scale,
        .height = bounds.height * scale,
    };
}

/// A screen point in physical pixels to logical client coordinates.
fn clientPoint(hwnd: win32.HWND, x: f64, y: f64) ?[2]f32 {
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    const scale = windowScale(hwnd) orelse return null;
    const origin = clientOrigin(hwnd) orelse return null;
    assert(scale > 0);
    return .{
        @floatCast((x - @as(f64, @floatFromInt(origin.x))) / scale),
        @floatCast((y - @as(f64, @floatFromInt(origin.y))) / scale),
    };
}

comptime {
    // `x86_64-windows` only; see `docs/windows-port.md`.
    assert(@sizeOf(usize) == 8);
    assert(@sizeOf(Provider) <= 96);
    assert(provider_count_max < index_none);
    assert(snapshot_mod.value_bytes_max <= bstr_bytes_max);
}

// =============================================================================
// Tests
// =============================================================================
//
// Methodology: drive the providers through their vtables exactly as UI
// Automation would, against a real hidden window (for DPI and screen
// coordinates) and a real `Tree`, then check every reference came back.

const testing = std.testing;
const Tree = tree_mod.Tree;

const TestFixture = struct {
    hwnd: win32.HWND,
    tree: *Tree,
    server: *Server,

    fn create() !TestFixture {
        const class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
        const instance = win32.GetModuleHandleW(null) orelse return error.NoModule;
        const hwnd = win32.CreateWindowExW(
            0,
            class,
            class,
            0,
            0,
            0,
            400,
            300,
            null,
            null,
            instance,
            null,
        ) orelse return error.WindowCreationFailed;
        errdefer _ = win32.DestroyWindow(hwnd);

        const tree = try testing.allocator.create(Tree);
        errdefer testing.allocator.destroy(tree);
        tree.initInPlace();

        const server = try testing.allocator.create(Server);
        errdefer testing.allocator.destroy(server);
        try server.initInPlace(hwnd);
        return .{ .hwnd = hwnd, .tree = tree, .server = server };
    }

    fn destroy(self: *TestFixture) void {
        self.server.lockExclusive();
        self.server.alive = false;
        self.server.unlockExclusive();
        _ = self.server.root.release();
        self.server.deinit();
        testing.allocator.destroy(self.server);
        testing.allocator.destroy(self.tree);
        _ = win32.DestroyWindow(self.hwnd);
    }

    /// A form with a labelled checkbox (checked) and a text field.
    fn buildForm(self: *TestFixture) void {
        self.tree.beginFrame();
        _ = self.tree.pushElement(.{ .role = .group, .name = "Settings" });
        _ = self.tree.pushElement(.{
            .role = .checkbox,
            .name = "Dark mode",
            .state = .{ .checked = true, .focused = true },
        });
        self.tree.popElement();
        _ = self.tree.pushElement(.{ .role = .textbox, .name = "Nickname", .value = "Zig" });
        self.tree.popElement();
        self.tree.popElement();
        self.tree.endFrame();
        self.tree.getElementMut(1).?.bounds = .{ .x = 10, .y = 20, .width = 100, .height = 24 };
        self.server.snapshot.rebuild(self.tree);
    }

    fn rootFragment(self: *TestFixture) *Fragment {
        return self.server.root.fragmentInterface();
    }
};

fn navigate(fragment: *Fragment, direction: i32) !?*Fragment {
    var result: ?*Fragment = null;
    try testing.expectEqual(uia.S_OK, fragment.vtable.Navigate(fragment, direction, &result));
    return result;
}

fn release(interface: anytype) void {
    _ = interface.vtable.Release(interface);
}

fn nameOf(fragment: *Fragment) ![]const u8 {
    var simple: ?*anyopaque = null;
    const iid = &uia.IID_IRawElementProviderSimple;
    try testing.expectEqual(uia.S_OK, fragment.vtable.QueryInterface(fragment, iid, &simple));
    const element: *Simple = @ptrCast(@alignCast(simple.?));
    defer release(element);
    var variant = uia.VARIANT.empty;
    const result = element.vtable.GetPropertyValue(element, uia.UIA_NamePropertyId, &variant);
    try testing.expectEqual(uia.S_OK, result);
    defer variantFree(&variant);
    try testing.expectEqual(uia.VT_BSTR, variant.vt);
    var buffer: [64]u8 = undefined;
    const units = std.mem.span(variant.value.bstrVal.?);
    const len = try std.unicode.utf16LeToUtf8(&buffer, units);
    return testing.allocator.dupe(u8, buffer[0..len]);
}

test "providers navigate the tree and report names and patterns" {
    var fixture = try TestFixture.create();
    defer fixture.destroy();
    fixture.buildForm();

    const group = (try navigate(fixture.rootFragment(), uia.NavigateDirection_FirstChild)).?;
    defer release(group);
    const checkbox = (try navigate(group, uia.NavigateDirection_FirstChild)).?;
    defer release(checkbox);
    const textbox = (try navigate(checkbox, uia.NavigateDirection_NextSibling)).?;
    defer release(textbox);
    const past_last = try navigate(textbox, uia.NavigateDirection_NextSibling);
    try testing.expectEqual(@as(?*Fragment, null), past_last);

    const name = try nameOf(checkbox);
    defer testing.allocator.free(name);
    try testing.expectEqualStrings("Dark mode", name);

    // The checkbox is a toggle, and reports its state; it is not a value.
    var toggle: ?*anyopaque = null;
    const iid = &uia.IID_IToggleProvider;
    try testing.expectEqual(uia.S_OK, checkbox.vtable.QueryInterface(checkbox, iid, &toggle));
    const toggler: *uia.IToggleProvider = @ptrCast(@alignCast(toggle.?));
    defer release(toggler);
    var state: i32 = -1;
    try testing.expectEqual(uia.S_OK, toggler.vtable.get_ToggleState(toggler, &state));
    try testing.expectEqual(uia.ToggleState_On, state);
    try testing.expectEqual(uia.UIA_E_NOTSUPPORTED, toggler.vtable.Toggle(toggler));
    var value: ?*anyopaque = null;
    const value_iid = &uia.IID_IValueProvider;
    const value_result = checkbox.vtable.QueryInterface(checkbox, value_iid, &value);
    try testing.expectEqual(uia.E_NOINTERFACE, value_result);
    try testing.expectEqual(@as(?*anyopaque, null), value);

    // Up from a top-level element is the root.
    const parent = (try navigate(group, uia.NavigateDirection_Parent)).?;
    defer release(parent);
    try testing.expectEqual(fixture.rootFragment(), parent);
}

test "the root finds focus and hit-tests in screen coordinates" {
    var fixture = try TestFixture.create();
    defer fixture.destroy();
    fixture.buildForm();

    const root: *FragmentRoot = @ptrCast(&fixture.server.root.fragment_root);
    var focused: ?*Fragment = null;
    try testing.expectEqual(uia.S_OK, root.vtable.GetFocus(root, &focused));
    defer release(focused.?);
    const focused_name = try nameOf(focused.?);
    defer testing.allocator.free(focused_name);
    try testing.expectEqualStrings("Dark mode", focused_name);

    // The checkbox's rectangle round-trips through the window's screen
    // position and DPI, and its centre hit-tests back to it.
    var rect = uia.UiaRect.empty;
    try testing.expectEqual(uia.S_OK, focused.?.vtable.get_BoundingRectangle(focused.?, &rect));
    try testing.expect(rect.width > 0);
    var hit: ?*Fragment = null;
    const centre_x = rect.left + rect.width / 2;
    const centre_y = rect.top + rect.height / 2;
    const hit_result = root.vtable.ElementProviderFromPoint(root, centre_x, centre_y, &hit);
    try testing.expectEqual(uia.S_OK, hit_result);
    defer release(hit.?);
    const hit_name = try nameOf(hit.?);
    defer testing.allocator.free(hit_name);
    try testing.expectEqualStrings("Dark mode", hit_name);
}

test "a removed element reports itself unavailable, and its provider is reclaimed" {
    var fixture = try TestFixture.create();
    defer fixture.destroy();
    fixture.buildForm();

    const group = (try navigate(fixture.rootFragment(), uia.NavigateDirection_FirstChild)).?;
    try testing.expectEqual(@as(u16, 1), fixture.server.live_count);

    fixture.tree.beginFrame();
    _ = fixture.tree.pushElement(.{ .role = .button, .name = "Other" });
    fixture.tree.popElement();
    fixture.tree.endFrame();
    fixture.server.snapshot.rebuild(fixture.tree);

    var rect = uia.UiaRect.empty;
    const result = group.vtable.get_BoundingRectangle(group, &rect);
    try testing.expectEqual(uia.UIA_E_ELEMENTNOTAVAILABLE, result);
    release(group);
    try testing.expectEqual(@as(u16, 0), fixture.server.live_count);
    try testing.expectEqual(@as(u16, 0), fixture.server.free_head);
}

test "the provider pool fills exactly, refuses one more, and reuses a released slot" {
    var fixture = try TestFixture.create();
    defer fixture.destroy();
    fixture.buildForm();
    const fingerprint = fixture.server.snapshot.entry(0).fingerprint;

    fixture.server.lockExclusive();
    var count: u16 = 0;
    while (count < provider_count_max) : (count += 1) {
        try testing.expect(fixture.server.claim(fingerprint) != null);
    }
    try testing.expectEqual(@as(?*Provider, null), fixture.server.claim(fingerprint));
    fixture.server.unlockExclusive();
    try testing.expect(fixture.server.exhaustion_logged);

    // Through the vtable, exhaustion is an error for the client, not a crash.
    const root = fixture.rootFragment();
    var refused: ?*Fragment = null;
    const first_child = uia.NavigateDirection_FirstChild;
    try testing.expectEqual(uia.E_OUTOFMEMORY, root.vtable.Navigate(root, first_child, &refused));
    try testing.expectEqual(@as(?*Fragment, null), refused);

    _ = fixture.server.providers[7].release();
    fixture.server.lockExclusive();
    const reused = fixture.server.claim(fingerprint).?;
    fixture.server.unlockExclusive();
    try testing.expectEqual(&fixture.server.providers[7], reused);

    for (fixture.server.providers) |*provider| _ = provider.release();
    try testing.expectEqual(@as(u16, 0), fixture.server.live_count);
}

test "runtime ids are unique per fingerprint and carry the append marker" {
    const first = runtimeId(tree_mod.Fingerprint.fromU64(0x0000_0001_FFFF_FFFE));
    try testing.expectEqual(uia.UiaAppendRuntimeId, first[0]);
    try testing.expectEqual(@as(i32, -2), first[1]);
    try testing.expectEqual(@as(i32, 1), first[2]);
    const second = runtimeId(tree_mod.Fingerprint.fromU64(0x0000_0002_FFFF_FFFE));
    try testing.expect(first[2] != second[2]);
}
