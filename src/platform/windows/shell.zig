//! Hand-written Shell bindings for the Windows file dialogs: the Common Item
//! Dialog (`IFileOpenDialog`, `IFileSaveDialog`) and the shell items it
//! returns.
//!
//! Only the subset of `shell32.dll` and `ole32.dll` the backend calls,
//! declared by hand for the same reasons as the WIC and DirectWrite bindings:
//! Gooey takes no package dependencies (CLAUDE.md §12) and the tree
//! type-checks from any host.
//!
//! These are COM interfaces. Each vtable lists every slot of its interface in
//! the order of `shobjidl_core.h`, because a method is found by its slot index
//! alone. Slots the backend never calls are typed `Slot`. A derived vtable
//! embeds its base vtable as the field `base`, which reproduces the C layout
//! of single inheritance. The comptime block at the end pins the slot of every
//! called method and the size of every vtable, so a missing or extra slot
//! fails to compile.
//!
//! Naming follows the SDK so each declaration can be checked against
//! Microsoft's documentation by name.

const std = @import("std");
const win32 = @import("win32.zig");

const assert = std.debug.assert;

// =============================================================================
// Scalar types
// =============================================================================

pub const HRESULT = i32;

pub const S_OK: HRESULT = 0;
/// `CoInitializeEx`: COM was already initialized on this thread, same model.
pub const S_FALSE: HRESULT = 1;
/// `CoInitializeEx`: COM was already initialized on this thread, other model.
pub const RPC_E_CHANGED_MODE: HRESULT = @bitCast(@as(u32, 0x8001_0106));
/// `IModalWindow::Show`: the user closed the dialog without choosing.
/// `HRESULT_FROM_WIN32(ERROR_CANCELLED)`.
pub const HRESULT_ERROR_CANCELLED: HRESULT = @bitCast(@as(u32, 0x8007_04C7));

/// `SUCCEEDED`: every non-negative `HRESULT` reports success.
pub fn succeeded(result: HRESULT) bool {
    return result >= 0;
}

/// A vtable slot the backend never calls. It only holds its place.
pub const Slot = *const anyopaque;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// One entry of the file type list: a display name and a `;`-separated list
/// of wildcard patterns.
pub const COMDLG_FILTERSPEC = extern struct {
    pszName: win32.LPCWSTR,
    pszSpec: win32.LPCWSTR,
};

// =============================================================================
// Class and interface identifiers
// =============================================================================

pub const CLSID_FileOpenDialog: GUID = .{
    .data1 = 0xDC1C_5A9C,
    .data2 = 0xE88A,
    .data3 = 0x4DDE,
    .data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 },
};

pub const CLSID_FileSaveDialog: GUID = .{
    .data1 = 0xC0B4_E2F3,
    .data2 = 0xBA21,
    .data3 = 0x4773,
    .data4 = .{ 0x8D, 0xBA, 0x33, 0x5E, 0xC9, 0x46, 0xEB, 0x8B },
};

pub const IID_IFileOpenDialog: GUID = .{
    .data1 = 0xD57C_7288,
    .data2 = 0xD4AD,
    .data3 = 0x4768,
    .data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 },
};

pub const IID_IFileSaveDialog: GUID = .{
    .data1 = 0x84BC_CD23,
    .data2 = 0x5FDE,
    .data3 = 0x4CDB,
    .data4 = .{ 0xAE, 0xA4, 0xAF, 0x64, 0xB8, 0x3D, 0x78, 0xAB },
};

pub const IID_IShellItem: GUID = .{
    .data1 = 0x4382_6D1E,
    .data2 = 0xE718,
    .data3 = 0x42EE,
    .data4 = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE },
};

// =============================================================================
// Enumerations and flags (C enums: 32 bits)
// =============================================================================

pub const COINIT_APARTMENTTHREADED: u32 = 0x2;
pub const COINIT_DISABLE_OLE1DDE: u32 = 0x4;
pub const CLSCTX_INPROC_SERVER: u32 = 0x1;

/// `SIGDN_FILESYSPATH`: the item's file system path, or failure for items
/// outside the file system.
pub const SIGDN_FILESYSPATH: u32 = 0x8005_8000;

// `FILEOPENDIALOGOPTIONS`.
pub const FOS_OVERWRITEPROMPT: u32 = 0x0000_0002;
pub const FOS_NOCHANGEDIR: u32 = 0x0000_0008;
pub const FOS_PICKFOLDERS: u32 = 0x0000_0020;
pub const FOS_FORCEFILESYSTEM: u32 = 0x0000_0040;
pub const FOS_ALLOWMULTISELECT: u32 = 0x0000_0200;
pub const FOS_PATHMUSTEXIST: u32 = 0x0000_0800;
pub const FOS_FILEMUSTEXIST: u32 = 0x0000_1000;

// =============================================================================
// Interfaces
// =============================================================================

/// `IFileDialog`, with its bases `IUnknown` and `IModalWindow`. Both dialogs
/// derive from it, so the backend configures and shows either through it.
pub const IFileDialog = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IFileDialog) callconv(.winapi) u32,
        // IModalWindow.
        Show: *const fn (*IFileDialog, ?win32.HWND) callconv(.winapi) HRESULT,
        // IFileDialog.
        SetFileTypes: *const fn (
            *IFileDialog,
            u32, // cFileTypes
            [*]const COMDLG_FILTERSPEC,
        ) callconv(.winapi) HRESULT,
        SetFileTypeIndex: Slot,
        GetFileTypeIndex: Slot,
        Advise: Slot,
        Unadvise: Slot,
        SetOptions: *const fn (*IFileDialog, u32) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*IFileDialog, *u32) callconv(.winapi) HRESULT,
        SetDefaultFolder: Slot,
        SetFolder: *const fn (*IFileDialog, *IShellItem) callconv(.winapi) HRESULT,
        GetFolder: Slot,
        GetCurrentSelection: Slot,
        SetFileName: *const fn (*IFileDialog, win32.LPCWSTR) callconv(.winapi) HRESULT,
        GetFileName: Slot,
        SetTitle: *const fn (*IFileDialog, win32.LPCWSTR) callconv(.winapi) HRESULT,
        SetOkButtonLabel: *const fn (*IFileDialog, win32.LPCWSTR) callconv(.winapi) HRESULT,
        SetFileNameLabel: Slot,
        GetResult: *const fn (*IFileDialog, *?*IShellItem) callconv(.winapi) HRESULT,
        AddPlace: Slot,
        /// Takes the extension without its leading dot.
        SetDefaultExtension: *const fn (
            *IFileDialog,
            win32.LPCWSTR,
        ) callconv(.winapi) HRESULT,
        Close: Slot,
        SetClientGuid: Slot,
        ClearClientData: Slot,
        SetFilter: Slot,
    };

    pub fn release(self: *IFileDialog) void {
        _ = self.vtable.Release(self);
    }
};

pub const IFileOpenDialog = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IFileDialog.VTable,
        GetResults: *const fn (
            *IFileOpenDialog,
            *?*IShellItemArray,
        ) callconv(.winapi) HRESULT,
        GetSelectedItems: Slot,
    };

    /// COM single inheritance: a derived interface pointer is also a pointer
    /// to each of its bases, and `base` lays out the base slots first.
    pub fn dialog(self: *IFileOpenDialog) *IFileDialog {
        return @ptrCast(self);
    }
};

pub const IFileSaveDialog = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        base: IFileDialog.VTable,
        SetSaveAsItem: Slot,
        SetProperties: Slot,
        SetCollectedProperties: Slot,
        GetProperties: Slot,
        ApplyProperties: Slot,
    };

    /// See `IFileOpenDialog.dialog`.
    pub fn dialog(self: *IFileSaveDialog) *IFileDialog {
        return @ptrCast(self);
    }
};

pub const IShellItem = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IShellItem) callconv(.winapi) u32,
        BindToHandler: Slot,
        GetParent: Slot,
        /// The name is allocated with `CoTaskMemAlloc`; the caller frees it
        /// with `CoTaskMemFree`.
        GetDisplayName: *const fn (
            *IShellItem,
            u32, // SIGDN
            *?[*:0]u16,
        ) callconv(.winapi) HRESULT,
        GetAttributes: Slot,
        Compare: Slot,
    };

    pub fn release(self: *IShellItem) void {
        _ = self.vtable.Release(self);
    }
};

pub const IShellItemArray = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: Slot,
        AddRef: Slot,
        Release: *const fn (*IShellItemArray) callconv(.winapi) u32,
        BindToHandler: Slot,
        GetPropertyStore: Slot,
        GetPropertyDescriptionList: Slot,
        GetAttributes: Slot,
        GetCount: *const fn (*IShellItemArray, *u32) callconv(.winapi) HRESULT,
        GetItemAt: *const fn (
            *IShellItemArray,
            u32, // dwIndex
            *?*IShellItem,
        ) callconv(.winapi) HRESULT,
        EnumItems: Slot,
    };

    pub fn release(self: *IShellItemArray) void {
        _ = self.vtable.Release(self);
    }
};

// =============================================================================
// Functions
// =============================================================================

pub extern "ole32" fn CoInitializeEx(
    pvReserved: ?*anyopaque,
    dwCoInit: u32,
) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

pub extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: u32,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

pub extern "shell32" fn SHCreateItemFromParsingName(
    pszPath: win32.LPCWSTR,
    pbc: ?*anyopaque,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

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

    assert(@sizeOf(GUID) == 16);
    assert(@sizeOf(COMDLG_FILTERSPEC) == 16);

    assertSlot(IFileDialog.VTable, "Release", 2);
    assertSlot(IFileDialog.VTable, "Show", 3);
    assertSlot(IFileDialog.VTable, "SetFileTypes", 4);
    assertSlot(IFileDialog.VTable, "SetOptions", 9);
    assertSlot(IFileDialog.VTable, "GetOptions", 10);
    assertSlot(IFileDialog.VTable, "SetFolder", 12);
    assertSlot(IFileDialog.VTable, "SetFileName", 15);
    assertSlot(IFileDialog.VTable, "SetTitle", 17);
    assertSlot(IFileDialog.VTable, "SetOkButtonLabel", 18);
    assertSlot(IFileDialog.VTable, "GetResult", 20);
    assertSlot(IFileDialog.VTable, "SetDefaultExtension", 22);
    assertSlotCount(IFileDialog.VTable, 27);

    assertSlot(IFileOpenDialog.VTable, "base", 0);
    assertSlot(IFileOpenDialog.VTable, "GetResults", 27);
    assertSlotCount(IFileOpenDialog.VTable, 29);

    assertSlot(IFileSaveDialog.VTable, "base", 0);
    assertSlotCount(IFileSaveDialog.VTable, 32);

    assertSlot(IShellItem.VTable, "Release", 2);
    assertSlot(IShellItem.VTable, "GetDisplayName", 5);
    assertSlotCount(IShellItem.VTable, 8);

    assertSlot(IShellItemArray.VTable, "Release", 2);
    assertSlot(IShellItemArray.VTable, "GetCount", 7);
    assertSlot(IShellItemArray.VTable, "GetItemAt", 8);
    assertSlotCount(IShellItemArray.VTable, 10);
}
