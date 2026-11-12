//! `zig build compile-hlsl`: compiles one HLSL entry point to DXBC with the
//! system `D3DCompiler_47.dll`.
//!
//! The DirectX 11 renderer embeds precompiled DXBC, checked in beside its
//! HLSL like the Vulkan renderer's `.spv` files, so no build and no running
//! app needs a shader compiler. This program regenerates one `.dxbc` after an
//! HLSL edit:
//!
//!     compile_hlsl <source.hlsl> <entry point> <profile> <output.dxbc>
//!
//! `D3DCompiler_47.dll` ships with Windows 10 and later, so regenerating needs
//! no Windows SDK, and Gooey takes no dependency (CLAUDE.md §12). Warnings
//! are errors, and strictness is on, so a shader that only compiles with
//! legacy syntax fails here rather than on a user's machine. The output is
//! the signed container `ID3D11Device::Create*Shader` validates.
//!
//! Bounds: a source smaller than `source_bytes_max`; failures print the
//! compiler's messages and exit with status 1.

const std = @import("std");
const builtin = @import("builtin");
const Dir = std.Io.Dir;

const assert = std.debug.assert;

const source_bytes_max: u32 = 256 * 1024;

/// `D3DCOMPILE_ENABLE_STRICTNESS | D3DCOMPILE_OPTIMIZATION_LEVEL3 |
/// D3DCOMPILE_WARNINGS_ARE_ERRORS` from `d3dcompiler.h`.
const compile_flags: u32 = (1 << 11) | (1 << 15) | (1 << 18);

/// `D3D_COMPILE_STANDARD_FILE_INCLUDE`: resolve `#include` relative to the
/// source file, by the sentinel pointer value 1 the header defines.
const standard_file_include: *anyopaque = @ptrFromInt(1);

const ID3DBlob = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*ID3DBlob) callconv(.winapi) u32,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) [*]const u8,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };

    fn bytes(self: *ID3DBlob) []const u8 {
        return self.vtable.GetBufferPointer(self)[0..self.vtable.GetBufferSize(self)];
    }
};

extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: [*]const u8,
    SrcDataSize: usize,
    pSourceName: [*:0]const u8,
    pDefines: ?*const anyopaque,
    pInclude: ?*anyopaque,
    pEntrypoint: [*:0]const u8,
    pTarget: [*:0]const u8,
    Flags1: u32,
    Flags2: u32,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: *?*ID3DBlob,
) callconv(.winapi) i32;

comptime {
    assert(builtin.os.tag == .windows);
    assert(@sizeOf(ID3DBlob.VTable) == 5 * @sizeOf(usize));
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) {
        std.debug.print("usage: compile_hlsl <source.hlsl> <entry> <profile> <output.dxbc>\n", .{});
        std.process.exit(2);
    }
    const source_path = args[1];
    const entry = args[2];
    const profile = args[3];
    const output_path = args[4];
    assert(source_path.len > 0);
    assert(output_path.len > 0);

    const buffer = try arena.alloc(u8, source_bytes_max);
    const source = try Dir.cwd().readFile(io, source_path, buffer);
    // A read that fills the buffer may have been cut short.
    if (source.len == buffer.len) {
        std.debug.panic("compile_hlsl: {s} is not smaller than source_bytes_max {d}", .{
            source_path,
            source_bytes_max,
        });
    }

    var code: ?*ID3DBlob = null;
    var messages: ?*ID3DBlob = null;
    const result = D3DCompile(
        source.ptr,
        source.len,
        source_path,
        null,
        standard_file_include,
        entry,
        profile,
        compile_flags,
        0,
        &code,
        &messages,
    );
    if (messages) |blob| {
        std.debug.print("{s}", .{blob.bytes()});
        _ = blob.vtable.Release(blob);
    }
    if (result < 0 or code == null) {
        std.debug.print("compile_hlsl: {s} {s} ({s}) failed: 0x{X:0>8}\n", .{
            source_path,
            entry,
            profile,
            @as(u32, @bitCast(result)),
        });
        std.process.exit(1);
    }
    defer _ = code.?.vtable.Release(code.?);

    const dxbc = code.?.bytes();
    // Every DXBC container begins with its four-byte magic.
    assert(std.mem.eql(u8, dxbc[0..4], "DXBC"));
    try Dir.cwd().writeFile(io, .{ .sub_path = output_path, .data = dxbc });
}
