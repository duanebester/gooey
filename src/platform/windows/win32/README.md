# Windows API bindings (curated zigwin32 subset)

A subset of the generated **marlersoft win32-zig** package
(`win32-25.0.28-preview-mX5pFWMt5QPTVIGh3r2-OpPunpcCCjApyRbA6Zn6WALH`,
fingerprint `0xb50ba1d115697e99`, minimum Zig 0.14), vendored so the Windows
backend keeps Gooey's zero-package-dependency, no-SDK model. `CLAUDE.md` §12
records the exception details below.

## Scope

Only the modules the platform layer actually uses are copied: windowing and
messages (`ui/windows_and_messaging`), input (`ui/input/keyboard_and_mouse`,
`ui/hi_dpi`), DPI, DWM vsync, GDI, D3D11/DXGI/D3DCompiler
(`graphics/*`), COM (`system/com.zig`), and the library-loader/threading
helpers. Files are copied verbatim from the generator output, with the
relative-import structure preserved so they compile unmodified. A few tiny
files (`system/diagnostics.zig`, `system/power.zig`, `ui/shell.zig`,
`ui/controls.zig`, `ui/text_services.zig`, `security.zig`) are SHIMs that
reproduce only the symbols the copied files reference, with their original
definitions, so the import closure stays small.

`zig.zig` is the generator's hand-maintained helper root (`Guid`,
`typedConst`, `FAILED`/`SUCCEEDED`, `unicode_mode`, …), not a Gooey module.
It is copied verbatim except for its module-root import: the upstream file
resolves helper types through the generated package root; here those imports
are relative paths into this tree so the vendored subset stands alone.

Two mechanical patches are applied to copied files for Zig 0.17:

- File-scope test blocks change `_ = @field(@This(), decl.name)` to `decl`
  (`std.meta.declarations` returns names now). Test blocks do not affect
  normal builds.
- `graphics/direct3d10.zig` keeps only the `ID3D10Effect` shape the D3DCompile
  signature needs; the full file's externs require d3d10 import libraries.

If a compile error reports a missing symbol from a SHIM, add that symbol with
its definition from the source package — do not edit a copied generated file.

`zig build-obj -fno-emit-bin -target x86_64-windows-gnu
src/platform/windows/win32/smoke_test.zig` from the repo root analyzes the
D3D11/DXGI binding closure (a plain root, so the generated files' own test
blocks are not executed). `zig build` links `d3d11`/`dxgi` import libraries;
`D3DCompile` is deliberately not linked — it is resolved at runtime via
`LoadLibraryA("d3dcompiler_47.dll")` in `dx11_renderer.zig`.

## Dependency-exception record (`CLAUDE.md` §12)

- **Supply-chain risk**: generated code copied once from a pinned package
  release; no package fetch, no build-time download, no C headers. Updating
  means re-copying from a known release and re-running the smoke test.
- **Supported platforms**: Windows targets only (`x86_64-windows-gnu`,
  `aarch64-windows-gnu`); the tree is imported only by `platform/windows/`.
- **Binary size**: roughly 3.3 MB of Zig source, but Zig analyzes declarations
  lazily, so only referenced symbols reach the binary. No runtime allocation
  or initialization is added by the bindings themselves.
- **Initialization / allocation behavior**: pure type and `extern` declarations;
  no global constructors, no lazy initialization.
- **Failure modes**: missing symbols are compile errors (add the definition to
  the relevant SHIM); ABI mismatches are link/runtime errors. Windows system
  DLLs are resolved by the mingw import libraries, not vendored.
- **Removal cost**: delete this directory and the `win32` imports in
  `platform/windows/*`; the binding layer has no state of its own. The
  replacement must supply the same Win32/D3D11 declarations.
