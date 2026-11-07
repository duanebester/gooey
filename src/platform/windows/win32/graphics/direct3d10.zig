//! Minimal direct3d10 shim for the vendored DX11 bindings.
//!
//! `graphics/direct3d/fxc.zig` (the D3DCompile entry point the renderer uses)
//! takes `?*ID3D10Effect` in one function signature. The full generated
//! direct3d10.zig (6k lines) declares 27 `extern "d3d10"/"d3d10_1"` functions
//! that link against import libraries the mingw toolchain does not ship, so
//! this shim keeps only the pointer-ABI-compatible interface type. Nothing in
//! gooey dereferences ID3D10Effect. Source:
//! win32-25.0.28-preview (marlersoft zigwin32gen), graphics/direct3d10.zig:5385.

const com = @import("../system/com.zig");
const Guid = @import("../zig.zig").Guid;
const BOOL = @import("../foundation.zig").BOOL;
const HRESULT = @import("../foundation.zig").HRESULT;

pub const ID3D10Device = opaque {};
pub const ID3D10EffectConstantBuffer = opaque {};
pub const ID3D10EffectVariable = opaque {};
pub const ID3D10EffectType = opaque {};
pub const ID3D10ShaderReflection = opaque {};

pub const ID3D10Effect = extern union {
    pub const VTable = extern struct {
        base: com.IUnknown.VTable,
        IsValid: *const fn(self: *const ID3D10Effect) callconv(.winapi) BOOL,
        IsPool: *const fn(self: *const ID3D10Effect) callconv(.winapi) BOOL,
        GetDevice: *const fn(self: *const ID3D10Effect, ppDevice: ?*?*ID3D10Device) callconv(.winapi) HRESULT,
        // Remaining slots are opaque: gooey never calls into an effect; the
        // slot count matches the generated vtable so pointer layout is stable.
        _slots: [24]*const anyopaque,
    };
    vtable: *const VTable,
    IUnknown: com.IUnknown,
};
