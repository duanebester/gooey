//! Hand-written UI Automation bindings for the Windows accessibility bridge
//! (`accessibility/windows_bridge.zig`).
//!
//! Only the provider side of `uiautomationcore.dll`, the `oleaut32.dll` string
//! and array helpers its out-parameters use, and the slim reader-writer lock
//! that guards the bridge's snapshot. Declared by hand for the same reasons as
//! the Shell, WIC, and DirectWrite bindings: Gooey takes no package
//! dependencies (CLAUDE.md §12) and the tree type-checks from any host.
//!
//! Gooey implements these interfaces rather than calling them, so every vtable
//! slot is typed: UI Automation calls a method by its slot index alone, in the
//! order of `uiautomationcore.h`. The comptime block at the end pins each slot
//! and each vtable size, and the IIDs match the header's `DEFINE_GUID` lines.
//!
//! Out-parameters are nullable pointers because a COM caller may pass null;
//! implementations return `E_POINTER` rather than writing through it.
//!
//! Naming follows the SDK so each declaration can be checked against
//! Microsoft's documentation by name.

const std = @import("std");
const win32 = @import("win32.zig");
const shell = @import("shell.zig");

const assert = std.debug.assert;

// =============================================================================
// Scalar types and results
// =============================================================================

pub const GUID = shell.GUID;
pub const HRESULT = shell.HRESULT;
pub const S_OK = shell.S_OK;
pub const succeeded = shell.succeeded;

pub const E_NOINTERFACE: HRESULT = @bitCast(@as(u32, 0x8000_4002));
pub const E_POINTER: HRESULT = @bitCast(@as(u32, 0x8000_4003));
pub const E_INVALIDARG: HRESULT = @bitCast(@as(u32, 0x8007_0057));
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(u32, 0x8007_000E));
/// The element behind a provider no longer exists in the UI.
pub const UIA_E_ELEMENTNOTAVAILABLE: HRESULT = @bitCast(@as(u32, 0x8004_0201));
/// The provider does not support the requested operation.
pub const UIA_E_NOTSUPPORTED: HRESULT = @bitCast(@as(u32, 0x8004_0204));

/// A length-prefixed UTF-16 string owned by `oleaut32`'s allocator. A provider
/// returns one through an out-parameter and the caller frees it.
pub const BSTR = [*:0]u16;

pub const VARIANT_BOOL = i16;
pub const VARIANT_TRUE: VARIANT_BOOL = -1;
pub const VARIANT_FALSE: VARIANT_BOOL = 0;

// `VARTYPE` tags.
pub const VT_EMPTY: u16 = 0;
pub const VT_I4: u16 = 3;
pub const VT_R8: u16 = 5;
pub const VT_BSTR: u16 = 8;
pub const VT_BOOL: u16 = 11;

/// `VARIANT`: a type tag and a 16-byte payload. Only the payloads the bridge
/// writes are named; `record` gives the union the size of the largest member.
pub const VARIANT = extern struct {
    vt: u16,
    reserved1: u16 = 0,
    reserved2: u16 = 0,
    reserved3: u16 = 0,
    value: Value,

    pub const Value = extern union {
        lVal: i32,
        dblVal: f64,
        boolVal: VARIANT_BOOL,
        bstrVal: ?BSTR,
        record: [2]usize,
    };

    pub const empty: VARIANT = .{ .vt = VT_EMPTY, .value = .{ .record = .{ 0, 0 } } };
};

pub const SAFEARRAY = opaque {};

/// A rectangle in screen coordinates, physical pixels.
pub const UiaRect = extern struct {
    left: f64,
    top: f64,
    width: f64,
    height: f64,

    pub const empty: UiaRect = .{ .left = 0, .top = 0, .width = 0, .height = 0 };
};

/// `SRWLOCK`: zero is the unlocked state (`SRWLOCK_INIT`).
pub const SRWLOCK = extern struct {
    ptr: ?*anyopaque = null,
};

// =============================================================================
// Identifiers (`uiautomationclient.h`, `uiautomationcore.h`)
// =============================================================================

/// `WM_GETOBJECT`'s object id for a UI Automation root request. The message
/// carries it in the low 32 bits of `lParam`.
pub const UiaRootObjectId: i32 = -25;
/// First element of a runtime id that asks UI Automation to prefix the host
/// window's id, making the rest unique only within this window.
pub const UiaAppendRuntimeId: i32 = 3;

// `ProviderOptions`.
pub const ProviderOptions_ServerSideProvider: i32 = 0x2;
pub const ProviderOptions_UseComThreading: i32 = 0x20;

// `NavigateDirection`.
pub const NavigateDirection_Parent: i32 = 0;
pub const NavigateDirection_NextSibling: i32 = 1;
pub const NavigateDirection_PreviousSibling: i32 = 2;
pub const NavigateDirection_FirstChild: i32 = 3;
pub const NavigateDirection_LastChild: i32 = 4;

// `StructureChangeType`.
pub const StructureChangeType_ChildrenInvalidated: i32 = 2;

// `NotificationKind` and `NotificationProcessing`.
pub const NotificationKind_Other: i32 = 4;
pub const NotificationProcessing_ImportantAll: i32 = 0;
pub const NotificationProcessing_All: i32 = 2;

// `ToggleState`.
pub const ToggleState_Off: i32 = 0;
pub const ToggleState_On: i32 = 1;

// `ExpandCollapseState`.
pub const ExpandCollapseState_Collapsed: i32 = 0;
pub const ExpandCollapseState_Expanded: i32 = 1;
pub const ExpandCollapseState_LeafNode: i32 = 3;

// `LiveSetting`.
pub const LiveSetting_Off: i32 = 0;
pub const LiveSetting_Polite: i32 = 1;
pub const LiveSetting_Assertive: i32 = 2;

// Heading levels: `HeadingLevel_None` and `HeadingLevel1`; levels 2-9 follow.
pub const HeadingLevel_None: i32 = 80050;
pub const HeadingLevel1: i32 = 80051;

// Pattern ids.
pub const UIA_ValuePatternId: i32 = 10002;
pub const UIA_RangeValuePatternId: i32 = 10003;
pub const UIA_ExpandCollapsePatternId: i32 = 10005;
pub const UIA_SelectionItemPatternId: i32 = 10010;
pub const UIA_TogglePatternId: i32 = 10015;

// Event ids.
pub const UIA_AutomationFocusChangedEventId: i32 = 20005;

// Property ids.
pub const UIA_ControlTypePropertyId: i32 = 30003;
pub const UIA_NamePropertyId: i32 = 30005;
pub const UIA_HasKeyboardFocusPropertyId: i32 = 30008;
pub const UIA_IsKeyboardFocusablePropertyId: i32 = 30009;
pub const UIA_IsEnabledPropertyId: i32 = 30010;
pub const UIA_HelpTextPropertyId: i32 = 30013;
pub const UIA_IsControlElementPropertyId: i32 = 30016;
pub const UIA_IsContentElementPropertyId: i32 = 30017;
pub const UIA_IsOffscreenPropertyId: i32 = 30022;
pub const UIA_FrameworkIdPropertyId: i32 = 30024;
pub const UIA_IsRequiredForFormPropertyId: i32 = 30025;
pub const UIA_ValueValuePropertyId: i32 = 30045;
pub const UIA_RangeValueValuePropertyId: i32 = 30047;
pub const UIA_ExpandCollapseExpandCollapseStatePropertyId: i32 = 30070;
pub const UIA_SelectionItemIsSelectedPropertyId: i32 = 30079;
pub const UIA_ToggleToggleStatePropertyId: i32 = 30086;
pub const UIA_AriaRolePropertyId: i32 = 30101;
pub const UIA_LiveSettingPropertyId: i32 = 30135;
pub const UIA_PositionInSetPropertyId: i32 = 30152;
pub const UIA_SizeOfSetPropertyId: i32 = 30153;
pub const UIA_HeadingLevelPropertyId: i32 = 30173;
pub const UIA_IsDialogPropertyId: i32 = 30174;

// Control type ids.
pub const UIA_ButtonControlTypeId: i32 = 50000;
pub const UIA_CheckBoxControlTypeId: i32 = 50002;
pub const UIA_ComboBoxControlTypeId: i32 = 50003;
pub const UIA_EditControlTypeId: i32 = 50004;
pub const UIA_HyperlinkControlTypeId: i32 = 50005;
pub const UIA_ImageControlTypeId: i32 = 50006;
pub const UIA_ListItemControlTypeId: i32 = 50007;
pub const UIA_ListControlTypeId: i32 = 50008;
pub const UIA_MenuControlTypeId: i32 = 50009;
pub const UIA_MenuBarControlTypeId: i32 = 50010;
pub const UIA_MenuItemControlTypeId: i32 = 50011;
pub const UIA_ProgressBarControlTypeId: i32 = 50012;
pub const UIA_RadioButtonControlTypeId: i32 = 50013;
pub const UIA_ScrollBarControlTypeId: i32 = 50014;
pub const UIA_SliderControlTypeId: i32 = 50015;
pub const UIA_SpinnerControlTypeId: i32 = 50016;
pub const UIA_StatusBarControlTypeId: i32 = 50017;
pub const UIA_TabControlTypeId: i32 = 50018;
pub const UIA_TabItemControlTypeId: i32 = 50019;
pub const UIA_TextControlTypeId: i32 = 50020;
pub const UIA_ToolBarControlTypeId: i32 = 50021;
pub const UIA_ToolTipControlTypeId: i32 = 50022;
pub const UIA_TreeControlTypeId: i32 = 50023;
pub const UIA_TreeItemControlTypeId: i32 = 50024;
pub const UIA_GroupControlTypeId: i32 = 50026;
pub const UIA_PaneControlTypeId: i32 = 50033;
pub const UIA_SeparatorControlTypeId: i32 = 50038;

pub const IID_IUnknown: GUID = .{
    .data1 = 0x0000_0000,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};

pub const IID_IRawElementProviderSimple: GUID = .{
    .data1 = 0xD6DD_68D1,
    .data2 = 0x86FD,
    .data3 = 0x4332,
    .data4 = .{ 0x86, 0x66, 0x9A, 0xBE, 0xDE, 0xA2, 0xD2, 0x4C },
};

pub const IID_IRawElementProviderFragment: GUID = .{
    .data1 = 0xF706_3DA8,
    .data2 = 0x8359,
    .data3 = 0x439C,
    .data4 = .{ 0x92, 0x97, 0xBB, 0xC5, 0x29, 0x9A, 0x7D, 0x87 },
};

pub const IID_IRawElementProviderFragmentRoot: GUID = .{
    .data1 = 0x620C_E2A5,
    .data2 = 0xAB8F,
    .data3 = 0x40A9,
    .data4 = .{ 0x86, 0xCB, 0xDE, 0x3C, 0x75, 0x59, 0x9B, 0x58 },
};

pub const IID_IValueProvider: GUID = .{
    .data1 = 0xC793_5180,
    .data2 = 0x6FB3,
    .data3 = 0x4201,
    .data4 = .{ 0xB1, 0x74, 0x7D, 0xF7, 0x3A, 0xDB, 0xF6, 0x4A },
};

pub const IID_IRangeValueProvider: GUID = .{
    .data1 = 0x36DC_7AEF,
    .data2 = 0x33E6,
    .data3 = 0x4691,
    .data4 = .{ 0xAF, 0xE1, 0x2B, 0xE7, 0x27, 0x4B, 0x3D, 0x33 },
};

pub const IID_IToggleProvider: GUID = .{
    .data1 = 0x56D0_0BD0,
    .data2 = 0xC4F4,
    .data3 = 0x433C,
    .data4 = .{ 0xA8, 0x36, 0x1A, 0x52, 0xA5, 0x7E, 0x08, 0x92 },
};

pub const IID_IExpandCollapseProvider: GUID = .{
    .data1 = 0xD847_D3A5,
    .data2 = 0xCAB0,
    .data3 = 0x4A98,
    .data4 = .{ 0x8C, 0x32, 0xEC, 0xB4, 0x5C, 0x59, 0xAD, 0x24 },
};

pub const IID_ISelectionItemProvider: GUID = .{
    .data1 = 0x2ACA_D808,
    .data2 = 0xB2D4,
    .data3 = 0x452D,
    .data4 = .{ 0xA4, 0x07, 0x91, 0xFF, 0x1A, 0xD1, 0x67, 0xB2 },
};

pub fn guidEql(a: *const GUID, b: *const GUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

// =============================================================================
// Interfaces
// =============================================================================

fn QueryInterfaceFn(comptime Interface: type) type {
    return *const fn (*Interface, ?*const GUID, ?*?*anyopaque) callconv(.winapi) HRESULT;
}

fn ReferenceFn(comptime Interface: type) type {
    return *const fn (*Interface) callconv(.winapi) u32;
}

fn ActionFn(comptime Interface: type) type {
    return *const fn (*Interface) callconv(.winapi) HRESULT;
}

fn GetFn(comptime Interface: type, comptime T: type) type {
    return *const fn (*Interface, ?*T) callconv(.winapi) HRESULT;
}

pub const IRawElementProviderSimple = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        get_ProviderOptions: GetFn(Self, i32),
        GetPatternProvider: *const fn (*Self, i32, ?*?*anyopaque) callconv(.winapi) HRESULT,
        GetPropertyValue: *const fn (*Self, i32, ?*VARIANT) callconv(.winapi) HRESULT,
        get_HostRawElementProvider: GetFn(Self, ?*IRawElementProviderSimple),
    };
};

pub const IRawElementProviderFragment = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        Navigate: *const fn (
            *Self,
            i32, // NavigateDirection
            ?*?*IRawElementProviderFragment,
        ) callconv(.winapi) HRESULT,
        GetRuntimeId: GetFn(Self, ?*SAFEARRAY),
        get_BoundingRectangle: GetFn(Self, UiaRect),
        GetEmbeddedFragmentRoots: GetFn(Self, ?*SAFEARRAY),
        SetFocus: ActionFn(Self),
        get_FragmentRoot: GetFn(Self, ?*IRawElementProviderFragmentRoot),
    };
};

pub const IRawElementProviderFragmentRoot = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        /// The point is in screen coordinates, physical pixels.
        ElementProviderFromPoint: *const fn (
            *Self,
            f64,
            f64,
            ?*?*IRawElementProviderFragment,
        ) callconv(.winapi) HRESULT,
        GetFocus: GetFn(Self, ?*IRawElementProviderFragment),
    };
};

pub const IValueProvider = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        SetValue: *const fn (*Self, ?win32.LPCWSTR) callconv(.winapi) HRESULT,
        get_Value: GetFn(Self, ?BSTR),
        get_IsReadOnly: GetFn(Self, win32.BOOL),
    };
};

pub const IRangeValueProvider = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        SetValue: *const fn (*Self, f64) callconv(.winapi) HRESULT,
        get_Value: GetFn(Self, f64),
        get_IsReadOnly: GetFn(Self, win32.BOOL),
        get_Maximum: GetFn(Self, f64),
        get_Minimum: GetFn(Self, f64),
        get_LargeChange: GetFn(Self, f64),
        get_SmallChange: GetFn(Self, f64),
    };
};

pub const IToggleProvider = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        Toggle: ActionFn(Self),
        get_ToggleState: GetFn(Self, i32),
    };
};

pub const IExpandCollapseProvider = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        Expand: ActionFn(Self),
        Collapse: ActionFn(Self),
        get_ExpandCollapseState: GetFn(Self, i32),
    };
};

pub const ISelectionItemProvider = extern struct {
    vtable: *const VTable,

    const Self = @This();
    pub const VTable = extern struct {
        QueryInterface: QueryInterfaceFn(Self),
        AddRef: ReferenceFn(Self),
        Release: ReferenceFn(Self),
        Select: ActionFn(Self),
        AddToSelection: ActionFn(Self),
        RemoveFromSelection: ActionFn(Self),
        get_IsSelected: GetFn(Self, win32.BOOL),
        get_SelectionContainer: GetFn(Self, ?*IRawElementProviderSimple),
    };
};

// =============================================================================
// Window host
// =============================================================================

/// The window half of the bridge, embedded in each platform window. The bridge
/// publishes its root provider here; the window procedure answers
/// `WM_GETOBJECT` with it and records that a client asked, which the bridge's
/// `isActive` reads. Both sides run on the window's thread.
pub const Host = struct {
    hwnd: ?win32.HWND = null,
    root: ?*IRawElementProviderSimple = null,
    /// Sticky: once a client has asked for the root, the bridge keeps the
    /// snapshot current for the window's lifetime.
    client_requested: bool = false,
};

/// Frames the window renders after a root request even with nothing to draw,
/// so the accessibility system's periodic screen reader poll runs promptly in
/// an idle app. Equal to `constants.SCREEN_READER_CHECK_INTERVAL`, which the
/// bridge asserts.
pub const activation_frame_count: u8 = 60;

// =============================================================================
// Functions
// =============================================================================

pub extern "uiautomationcore" fn UiaReturnRawElementProvider(
    hwnd: win32.HWND,
    wParam: win32.WPARAM,
    lParam: win32.LPARAM,
    el: ?*IRawElementProviderSimple,
) callconv(.winapi) win32.LRESULT;

pub extern "uiautomationcore" fn UiaHostProviderFromHwnd(
    hwnd: win32.HWND,
    ppProvider: *?*IRawElementProviderSimple,
) callconv(.winapi) HRESULT;

pub extern "uiautomationcore" fn UiaRaiseAutomationEvent(
    pProvider: *IRawElementProviderSimple,
    id: i32,
) callconv(.winapi) HRESULT;

pub extern "uiautomationcore" fn UiaRaiseAutomationPropertyChangedEvent(
    pProvider: *IRawElementProviderSimple,
    id: i32,
    oldValue: VARIANT,
    newValue: VARIANT,
) callconv(.winapi) HRESULT;

pub extern "uiautomationcore" fn UiaRaiseStructureChangedEvent(
    pProvider: *IRawElementProviderSimple,
    structureChangeType: i32,
    pRuntimeId: ?[*]i32,
    cRuntimeIdLen: i32,
) callconv(.winapi) HRESULT;

/// Windows 10 1709 and later.
pub extern "uiautomationcore" fn UiaRaiseNotificationEvent(
    provider: *IRawElementProviderSimple,
    notificationKind: i32,
    notificationProcessing: i32,
    displayString: ?BSTR,
    activityId: ?BSTR,
) callconv(.winapi) HRESULT;

pub extern "uiautomationcore" fn UiaClientsAreListening() callconv(.winapi) win32.BOOL;

pub extern "uiautomationcore" fn UiaDisconnectProvider(
    pProvider: *IRawElementProviderSimple,
) callconv(.winapi) HRESULT;

pub extern "oleaut32" fn SysAllocStringLen(
    strIn: ?[*]const u16,
    ui: u32,
) callconv(.winapi) ?BSTR;

pub extern "oleaut32" fn SysFreeString(bstrString: ?BSTR) callconv(.winapi) void;

pub extern "oleaut32" fn SafeArrayCreateVector(
    vt: u16,
    lLbound: i32,
    cElements: u32,
) callconv(.winapi) ?*SAFEARRAY;

pub extern "oleaut32" fn SafeArrayPutElement(
    psa: *SAFEARRAY,
    rgIndices: *const i32,
    pv: *const anyopaque,
) callconv(.winapi) HRESULT;

pub extern "oleaut32" fn SafeArrayDestroy(psa: *SAFEARRAY) callconv(.winapi) HRESULT;

pub extern "kernel32" fn AcquireSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;
pub extern "kernel32" fn ReleaseSRWLockExclusive(SRWLock: *SRWLOCK) callconv(.winapi) void;

// =============================================================================
// Layout pins
// =============================================================================

fn assertSlot(comptime VTable: type, comptime name: []const u8, comptime slot: u32) void {
    assert(@offsetOf(VTable, name) == slot * @sizeOf(usize));
}

fn assertSlotCount(comptime VTable: type, comptime count: u32) void {
    assert(@sizeOf(VTable) == count * @sizeOf(usize));
}

comptime {
    // `x86_64-windows` only; see `docs/windows-port.md`.
    assert(@sizeOf(usize) == 8);

    assert(@sizeOf(VARIANT) == 24);
    assert(@offsetOf(VARIANT, "value") == 8);
    assert(@sizeOf(UiaRect) == 32);
    assert(@sizeOf(SRWLOCK) == @sizeOf(usize));

    assertSlot(IRawElementProviderSimple.VTable, "get_ProviderOptions", 3);
    assertSlot(IRawElementProviderSimple.VTable, "get_HostRawElementProvider", 6);
    assertSlotCount(IRawElementProviderSimple.VTable, 7);

    assertSlot(IRawElementProviderFragment.VTable, "Navigate", 3);
    assertSlot(IRawElementProviderFragment.VTable, "get_FragmentRoot", 8);
    assertSlotCount(IRawElementProviderFragment.VTable, 9);

    assertSlot(IRawElementProviderFragmentRoot.VTable, "ElementProviderFromPoint", 3);
    assertSlotCount(IRawElementProviderFragmentRoot.VTable, 5);

    assertSlot(IValueProvider.VTable, "SetValue", 3);
    assertSlotCount(IValueProvider.VTable, 6);

    assertSlot(IRangeValueProvider.VTable, "SetValue", 3);
    assertSlot(IRangeValueProvider.VTable, "get_SmallChange", 9);
    assertSlotCount(IRangeValueProvider.VTable, 10);

    assertSlot(IToggleProvider.VTable, "Toggle", 3);
    assertSlotCount(IToggleProvider.VTable, 5);

    assertSlot(IExpandCollapseProvider.VTable, "Expand", 3);
    assertSlotCount(IExpandCollapseProvider.VTable, 6);

    assertSlot(ISelectionItemProvider.VTable, "Select", 3);
    assertSlot(ISelectionItemProvider.VTable, "get_SelectionContainer", 7);
    assertSlotCount(ISelectionItemProvider.VTable, 8);
}
