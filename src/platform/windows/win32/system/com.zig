//! Minimal IUnknown shim for the vendored DX11/DXGI bindings.
//!
//! The generated files only reference `IUnknown` (as the vtable base of every
//! COM interface); the full generated `system/com.zig` pulls in ole/urlmon/ui
//! cascades the renderer never touches. Definition copied verbatim from the
//! source package (`win32-25.0.28-preview`, system/com.zig:617).

const Guid = @import("../zig.zig").Guid;
const HRESULT = @import("../foundation.zig").HRESULT;
const PWSTR = @import("../foundation.zig").PWSTR;
const LARGE_INTEGER = @import("../foundation.zig").LARGE_INTEGER;
const ULARGE_INTEGER = @import("../foundation.zig").ULARGE_INTEGER;
const FILETIME = @import("../foundation.zig").FILETIME;

pub const IUnknown = extern union {
    pub const VTable = extern struct {
        QueryInterface: *const fn(
            self: *const IUnknown,
            riid: *const Guid,
            ppvObject: **anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const fn(
            self: *const IUnknown,
        ) callconv(.winapi) u32,
        Release: *const fn(
            self: *const IUnknown,
        ) callconv(.winapi) u32,
    };
    vtable: *const VTable,
    pub fn QueryInterface(self: *const IUnknown, riid: *const Guid, ppvObject: **anyopaque) callconv(.@"inline") HRESULT {
        return self.vtable.QueryInterface(self, riid, ppvObject);
    }
    pub fn AddRef(self: *const IUnknown) callconv(.@"inline") u32 {
        return self.vtable.AddRef(self);
    }
    pub fn Release(self: *const IUnknown) callconv(.@"inline") u32 {
        return self.vtable.Release(self);
    }
};

const IID_IUnknown_Value = Guid.initString("00000000-0000-0000-c000-000000000046");
pub const IID_IUnknown = &IID_IUnknown_Value;

// IMalloc and IStream are referenced by dxc.zig only as pointer types in
// method signatures (D3DCompiler-style creation callbacks); definitions are
// copied verbatim from the source package (system/com.zig:769/:1093 with the
// inline wrappers trimmed to what the signatures share).

pub const IMalloc = extern union {
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        Alloc: *const fn(
            self: *const IMalloc,
            cb: usize,
        ) callconv(.winapi) ?*anyopaque,
        Realloc: *const fn(
            self: *const IMalloc,
            pv: ?*anyopaque,
            cb: usize,
        ) callconv(.winapi) ?*anyopaque,
        Free: *const fn(
            self: *const IMalloc,
            pv: ?*anyopaque,
        ) callconv(.winapi) void,
        GetSize: *const fn(
            self: *const IMalloc,
            pv: ?*anyopaque,
        ) callconv(.winapi) usize,
        DidAlloc: *const fn(
            self: *const IMalloc,
            pv: ?*anyopaque,
        ) callconv(.winapi) i32,
        HeapMinimize: *const fn(
            self: *const IMalloc,
        ) callconv(.winapi) void,
    };
    vtable: *const VTable,
    IUnknown: IUnknown,
};

const IID_IMalloc_Value = Guid.initString("00000002-0000-0000-c000-000000000046");
pub const IID_IMalloc = &IID_IMalloc_Value;

pub const STATSTG = extern struct {
    pwcsName: ?PWSTR,
    type: u32,
    cbSize: ULARGE_INTEGER,
    mtime: FILETIME,
    ctime: FILETIME,
    atime: FILETIME,
    grfMode: u32,
    grfLocksSupported: u32,
    clsid: Guid,
    grfStateBits: u32,
    reserved: u32,
};

pub const STREAM_SEEK = enum(u32) {
    SET = 0,
    CUR = 1,
    END = 2,
};

pub const ISequentialStream = extern union {
    pub const VTable = extern struct {
        base: IUnknown.VTable,
        Read: *const fn(
            self: *const ISequentialStream,
            pv: ?*anyopaque,
            cb: u32,
            pcbRead: ?*u32,
        ) callconv(.winapi) HRESULT,
        Write: *const fn(
            self: *const ISequentialStream,
            pv: ?*const anyopaque,
            cb: u32,
            pcbWritten: ?*u32,
        ) callconv(.winapi) HRESULT,
    };
    vtable: *const VTable,
    IUnknown: IUnknown,
};

pub const IStream = extern union {
    pub const VTable = extern struct {
        base: ISequentialStream.VTable,
        Seek: *const fn(
            self: *const IStream,
            dlibMove: LARGE_INTEGER,
            dwOrigin: STREAM_SEEK,
            plibNewPosition: ?*ULARGE_INTEGER,
        ) callconv(.winapi) HRESULT,
        SetSize: *const fn(
            self: *const IStream,
            libNewSize: ULARGE_INTEGER,
        ) callconv(.winapi) HRESULT,
        CopyTo: *const anyopaque,
        Commit: *const anyopaque,
        Revert: *const anyopaque,
        LockRegion: *const anyopaque,
        UnlockRegion: *const anyopaque,
        Stat: *const fn(
            self: *const IStream,
            pstatstg: *STATSTG,
            grfStatFlag: u32,
        ) callconv(.winapi) HRESULT,
        Clone: *const anyopaque,
    };
    vtable: *const VTable,
    ISequentialStream: ISequentialStream,
    IUnknown: IUnknown,
};
