//! Exact compile-time verification of the platform boundary.
//!
//! Gooey binds to one backend per target (`platform/mod.zig`). Zig only
//! analyzes the selected backend, so nothing previously proved that the *other*
//! backends could still satisfy the calls shared runtime code makes. The old
//! `core/interface_verify.zig` platform checks used `@hasDecl` and inspected
//! two declarations (`init`, `deinit`) out of roughly thirty, which let real
//! drift accumulate: `getScaleFactor` returned `f32` on web and `f64`
//! elsewhere, size getters were `width`/`height` on macOS but
//! `getWidth`/`getHeight` on Linux, and `setActiveWindow` took a `?WindowId`
//! on macOS but a `*Window` on Linux.
//!
//! This module checks complete function types — parameter types and order,
//! receiver mutability, numeric widths, error-union presence, and payload
//! types — so a signature change fails to compile with a message naming the
//! offending declaration.
//!
//! ## Why a descriptor instead of comparing whole `fn` types
//!
//! Backends use inferred error sets (`!*Self`), so an expected type written as
//! `fn (...) anyerror!*Self` would never compare equal. `Sig` therefore states
//! the parameter list and the *payload* type, plus whether an error union is
//! required, and the verifier destructures `@typeInfo` to compare piecewise.
//!
//! ## Usage
//!
//! Each backend pins itself in a comptime block:
//!
//! ```zig
//! comptime {
//!     contract.verifyBackend(@This());
//! }
//! ```

const std = @import("std");
const builtin = @import("builtin");

const geometry = @import("../core/geometry.zig");
const scene_mod = @import("../scene/mod.zig");
const text_mod = @import("../text/mod.zig");
const input = @import("../input/mod.zig");
const interface = @import("interface.zig");

const WindowId = interface.WindowId;
const WindowOptions = interface.WindowOptions;
const CursorShape = interface.CursorShape;
const GlassStyle = interface.GlassStyle;
const DriveModel = interface.DriveModel;
const PlatformCapabilities = interface.PlatformCapabilities;

// =============================================================================
// Signature descriptors
// =============================================================================

/// Whether a verified declaration must return an error union.
pub const ErrorPolicy = enum {
    /// The return type must be `E!Payload` for some error set `E`.
    required,
    /// The return type must be exactly the payload type.
    forbidden,
};

/// One expected function signature.
pub const Sig = struct {
    /// Parameter types in declaration order, receiver included.
    params: []const type,
    /// Return payload type, with any error union already unwrapped.
    returns: type,
    /// Whether the declaration must be fallible.
    errors: ErrorPolicy = .forbidden,
};

// =============================================================================
// Primitive checks
// =============================================================================

/// Verify that `Owner.name` is a function exactly matching `sig`.
pub fn verifyFn(
    comptime Owner: type,
    comptime name: []const u8,
    comptime sig: Sig,
) void {
    comptime {
        if (!@hasDecl(Owner, name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} is missing required declaration '{s}': expected {s}",
                .{ @typeName(Owner), name, describe(sig) },
            ));
        }

        const Actual = @TypeOf(@field(Owner, name));
        const info = switch (@typeInfo(Actual)) {
            .@"fn" => |f| f,
            else => @compileError(std.fmt.comptimePrint(
                "{s}.{s} must be a function, found {s}",
                .{ @typeName(Owner), name, @typeName(Actual) },
            )),
        };

        if (info.is_var_args) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} must not be variadic",
                .{ @typeName(Owner), name },
            ));
        }
        if (info.is_generic) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} must not be generic; the platform boundary needs a concrete" ++
                    " signature so every backend can be checked uniformly",
                .{ @typeName(Owner), name },
            ));
        }

        verifyFnParams(Owner, name, sig, info.params);
        verifyFnReturn(Owner, name, sig, info.return_type);
    }
}

/// Compare a declaration's parameter list against `sig`, receiver included.
fn verifyFnParams(
    comptime Owner: type,
    comptime name: []const u8,
    comptime sig: Sig,
    comptime params: []const std.builtin.Type.Fn.Param,
) void {
    comptime {
        if (params.len != sig.params.len) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} takes {d} parameter(s), expected {d}: {s}",
                .{ @typeName(Owner), name, params.len, sig.params.len, describe(sig) },
            ));
        }

        for (params, sig.params, 0..) |actual_param, Expected, index| {
            const Param = actual_param.type orelse @compileError(std.fmt.comptimePrint(
                "{s}.{s} parameter {d} has no concrete type (comptime or anytype)",
                .{ @typeName(Owner), name, index },
            ));
            if (Param != Expected) {
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} parameter {d} is {s}, expected {s}",
                    .{ @typeName(Owner), name, index, @typeName(Param), @typeName(Expected) },
                ));
            }
        }
    }
}

/// Compare a declaration's return type against `sig`, honouring `ErrorPolicy`.
fn verifyFnReturn(
    comptime Owner: type,
    comptime name: []const u8,
    comptime sig: Sig,
    comptime declared: ?type,
) void {
    comptime {
        const Return = declared orelse @compileError(std.fmt.comptimePrint(
            "{s}.{s} has no concrete return type",
            .{ @typeName(Owner), name },
        ));

        switch (sig.errors) {
            .required => {
                const payload = switch (@typeInfo(Return)) {
                    .error_union => |u| u.payload,
                    else => @compileError(std.fmt.comptimePrint(
                        "{s}.{s} must be fallible and return an error union, found {s}",
                        .{ @typeName(Owner), name, @typeName(Return) },
                    )),
                };
                if (payload != sig.returns) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} returns error union payload {s}, expected {s}",
                        .{ @typeName(Owner), name, @typeName(payload), @typeName(sig.returns) },
                    ));
                }
            },
            .forbidden => {
                if (@typeInfo(Return) == .error_union) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} must be infallible, found error union {s}",
                        .{ @typeName(Owner), name, @typeName(Return) },
                    ));
                }
                if (Return != sig.returns) {
                    @compileError(std.fmt.comptimePrint(
                        "{s}.{s} returns {s}, expected {s}",
                        .{ @typeName(Owner), name, @typeName(Return), @typeName(sig.returns) },
                    ));
                }
            },
        }
    }
}

/// Verify that `Owner.name` is a non-function declaration of type `Expected`.
pub fn verifyConst(
    comptime Owner: type,
    comptime name: []const u8,
    comptime Expected: type,
) void {
    comptime {
        if (!@hasDecl(Owner, name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} is missing required constant '{s}: {s}'",
                .{ @typeName(Owner), name, @typeName(Expected) },
            ));
        }
        const Actual = @TypeOf(@field(Owner, name));
        if (Actual != Expected) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} is {s}, expected {s}",
                .{ @typeName(Owner), name, @typeName(Actual), @typeName(Expected) },
            ));
        }
    }
}

/// Verify that `Owner.name` is a type declaration exactly equal to `Expected`.
pub fn verifyType(
    comptime Owner: type,
    comptime name: []const u8,
    comptime Expected: type,
) void {
    comptime {
        if (!@hasDecl(Owner, name)) {
            @compileError(std.fmt.comptimePrint(
                "{s} is missing required type '{s}': expected {s}",
                .{ @typeName(Owner), name, @typeName(Expected) },
            ));
        }
        const Actual = @field(Owner, name);
        if (@TypeOf(Actual) != type) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} must be a type",
                .{ @typeName(Owner), name },
            ));
        }
        if (Actual != Expected) {
            @compileError(std.fmt.comptimePrint(
                "{s}.{s} is {s}, expected {s}",
                .{ @typeName(Owner), name, @typeName(Actual), @typeName(Expected) },
            ));
        }
    }
}

/// Verify that `Owner` has a field `name` of exactly type `Expected`.
///
/// ## Why fields are pinned, not only methods
///
/// Pinning `getSize` and `getScaleFactor` proves nothing about the calls
/// shared framework code actually makes: `context/window.zig` and
/// `runtime/multi_window_app.zig` read `platform_window.size.width`,
/// `.size.height`, and `.scale_factor` *directly* in roughly a dozen places
/// and never call the getters. Those reads are a dependency on the boundary
/// that no method check can see.
///
/// Zig makes the two interact rather than merely coexist: declarations and
/// fields share one namespace per container, so a method named `width` and a
/// field named `width` cannot both exist. That collision already fired in
/// this refactor — Linux had to rename its `width`/`height` fields to
/// `width_px`/`height_px` because the contract claimed those names as
/// methods. Had `size` collided the same way, a backend would have renamed
/// it, shared code would have stopped compiling, and the contract would have
/// stayed green because it never mentioned the field.
///
/// `@hasField` answers presence but not type, so this destructures
/// `@typeInfo` to compare the declared type and name both containers in the
/// error.
pub fn verifyField(
    comptime Owner: type,
    comptime name: []const u8,
    comptime Expected: type,
) void {
    comptime {
        const fields = switch (@typeInfo(Owner)) {
            .@"struct" => |s| s.fields,
            else => @compileError(std.fmt.comptimePrint(
                "{s} must be a struct to carry field '{s}'",
                .{ @typeName(Owner), name },
            )),
        };

        for (fields) |field| {
            if (!std.mem.eql(u8, field.name, name)) continue;
            if (field.type != Expected) {
                @compileError(std.fmt.comptimePrint(
                    "{s}.{s} is field type {s}, expected {s}; shared code reads this" ++
                        " field directly, so a differing type is a silent miscompile",
                    .{ @typeName(Owner), name, @typeName(field.type), @typeName(Expected) },
                ));
            }
            return;
        }

        @compileError(std.fmt.comptimePrint(
            "{s} is missing required field '{s}: {s}'",
            .{ @typeName(Owner), name, @typeName(Expected) },
        ));
    }
}

/// Render a signature descriptor for compile-error messages.
fn describe(comptime sig: Sig) []const u8 {
    comptime {
        var text: []const u8 = "fn (";
        for (sig.params, 0..) |Param, index| {
            if (index > 0) text = text ++ ", ";
            text = text ++ @typeName(Param);
        }
        text = text ++ ") ";
        if (sig.errors == .required) text = text ++ "!";
        return text ++ @typeName(sig.returns);
    }
}

// =============================================================================
// Platform contract
// =============================================================================

/// Verify a backend `Platform` type.
///
/// Covers host lifecycle, the bounded window registry, and the comptime
/// capability declarations. Every call here is made by `runtime/runner.zig`,
/// `runtime/multi_window_app.zig`, or `app.zig`.
pub fn verifyPlatform(comptime Platform: type) void {
    comptime {
        const self_mut: type = *Platform;
        const self_const: type = *const Platform;

        // Lifecycle. `initInPlace` rather than a by-value `init` because
        // Wayland registry listeners retain `&self`, so the final address must
        // exist before initialization completes. See design doc phase 3.
        verifyFn(Platform, "initInPlace", .{
            .params = &.{ self_mut, std.mem.Allocator },
            .returns = void,
            .errors = .required,
        });
        verifyFn(Platform, "deinit", .{ .params = &.{self_mut}, .returns = void });
        verifyFn(Platform, "run", .{ .params = &.{self_mut}, .returns = void });
        verifyFn(Platform, "quit", .{ .params = &.{self_mut}, .returns = void });

        // `isRunning` reports whether the host loop has been started and not
        // yet stopped. Exactly:
        //
        //   - false after `initInPlace` and before `run`;
        //   - true from the moment `run` is entered;
        //   - false from the moment `quit` returns.
        //
        // It is not "this backend is usable" and not "a frame is in flight".
        // The narrow reading is forced by `host_callback` backends, where the
        // host asks after every frame whether to schedule another one (see
        // `verifyBackend`): answering true before `run` would let a host that
        // polls during initialization start a frame chain against a
        // half-built application, and answering true after `quit` would never
        // let the chain stop. Backends previously disagreed — web reported
        // true from `initInPlace` — which made the one required use unusable.
        //
        // A comptime check cannot prove behaviour, so the three transitions
        // are pinned by tests in `src/testing/test_backend.zig`.
        verifyFn(Platform, "isRunning", .{ .params = &.{self_const}, .returns = bool });

        // Bounded window registry.
        verifyFn(Platform, "registerWindow", .{
            .params = &.{ self_mut, *anyopaque },
            .returns = WindowId,
            .errors = .required,
        });
        verifyFn(Platform, "unregisterWindow", .{
            .params = &.{ self_mut, WindowId },
            .returns = void,
        });
        verifyFn(Platform, "getWindow", .{
            .params = &.{ self_const, WindowId },
            .returns = ?*anyopaque,
        });
        verifyFn(Platform, "getActiveWindowId", .{
            .params = &.{self_const},
            .returns = ?WindowId,
        });
        verifyFn(Platform, "setActiveWindowId", .{
            .params = &.{ self_mut, ?WindowId },
            .returns = void,
        });
        verifyFn(Platform, "windowCount", .{ .params = &.{self_const}, .returns = u32 });

        // Per-turn owner hook.
        //
        // The one point in the host's cycle where the owner is provably *not*
        // inside a window's dispatch. That property is what the hook exists
        // for: a window closed by the titlebar or the compositor records
        // `isClosed()` from inside its own teardown, where destroying its
        // `WindowContext` would free the `Cx` the host is still unwinding
        // through. Without a hook the owner never learns, so
        // `App.drainClosedWindows` was only reachable from `openWindow`,
        // `closeWindowById`, and `deinit` — and a host-initiated close leaked
        // the context until one of those happened to run.
        //
        // "Turn" is deliberately not "frame": a backend must fire this once
        // per iteration of its host cycle whether or not anything rendered,
        // because the close that needs reclaiming may be the reason nothing
        // will ever render again. For `blocking_event_loop` backends the turn
        // is one pass of the loop inside `run`; for `host_callback` backends
        // it is one host callback.
        //
        // Backends must fire it outside any window callback and must tolerate
        // the callback calling back in — reclamation unregisters windows and
        // can call `quit`. A comptime check cannot prove placement, so the
        // ordering is pinned by tests against `src/testing/test_backend.zig`.
        verifyType(Platform, "LoopTurnCallback", *const fn (*Platform) void);
        verifyFn(Platform, "setLoopTurnCallback", .{
            .params = &.{ self_mut, ?Platform.LoopTurnCallback },
            .returns = void,
        });

        // Comptime backend properties.
        verifyConst(Platform, "capabilities", PlatformCapabilities);
    }
}

// =============================================================================
// Platform window contract
// =============================================================================

/// Verify a backend `PlatformWindow` type against its owning `Platform`.
///
/// The pinned surface stays discoverable from this one place; each group below
/// is a coherent responsibility rather than a fragment split to satisfy the
/// 70-line limit (`CLAUDE.md` §5).
pub fn verifyPlatformWindow(comptime Platform: type, comptime Window: type) void {
    comptime {
        verifyWindowLifecycle(Platform, Window);
        verifyWindowGeometry(Window);
        verifyWindowProperties(Window);
        verifyWindowHostControl(Window);
        verifyGlassStyleControl(Platform, Window);
        verifyFrameHandoff(Window);
        verifyImeBridge(Window);
        verifyCallbacks(Window);
    }
}

/// Verify construction, teardown, and identity.
fn verifyWindowLifecycle(comptime Platform: type, comptime Window: type) void {
    comptime {
        // Options cross the boundary by const pointer: the struct is far over
        // the 16-byte by-value threshold.
        verifyFn(Window, "init", .{
            .params = &.{ std.mem.Allocator, *Platform, *const WindowOptions },
            .returns = *Window,
            .errors = .required,
        });
        verifyFn(Window, "deinit", .{ .params = &.{*Window}, .returns = void });
        verifyFn(Window, "getWindowId", .{
            .params = &.{*const Window},
            .returns = WindowId,
        });

        // Every backend already retains its owning platform so `deinit` can
        // unregister without the caller tracking the pairing — but under three
        // different field names (`plat` on macOS, `platform` on Linux and web).
        // Shared code that needed the platform therefore had to branch on the
        // target to spell the field, which is how `context/window.zig`'s
        // `Window.quit()` ended up with a three-way `is_wasm`/`is_linux`/macOS
        // split whose arms had drifted apart. Publishing the back-pointer as a
        // method puts it under the verifier and lets shared code ask once.
        verifyFn(Window, "getPlatform", .{
            .params = &.{*Window},
            .returns = *Platform,
        });
    }
}

/// Verify the size and scale surface, both fields and getters.
///
/// Widths are pinned because web previously returned `f32` from
/// `getScaleFactor` while native returned `f64`, so a shared caller silently
/// lost precision on one target. The two fields are pinned for the reason
/// documented on `verifyField`: shared code reads them directly and never
/// calls the getters, so the getters alone verify the wrong thing.
fn verifyWindowGeometry(comptime Window: type) void {
    comptime {
        const self_const: type = *const Window;

        verifyField(Window, "size", geometry.Size(f64));
        verifyField(Window, "scale_factor", f64);

        verifyFn(Window, "width", .{ .params = &.{self_const}, .returns = u32 });
        verifyFn(Window, "height", .{ .params = &.{self_const}, .returns = u32 });
        verifyFn(Window, "getSize", .{
            .params = &.{self_const},
            .returns = geometry.Size(f64),
        });
        verifyFn(Window, "getScaleFactor", .{ .params = &.{self_const}, .returns = f64 });
    }
}

/// Verify native appearance, cursor, and pointer-state accessors.
fn verifyWindowProperties(comptime Window: type) void {
    comptime {
        const self_mut: type = *Window;
        const self_const: type = *const Window;

        verifyFn(Window, "setTitle", .{
            .params = &.{ self_mut, []const u8 },
            .returns = void,
        });
        verifyFn(Window, "setBackgroundColor", .{
            .params = &.{ self_mut, geometry.Color },
            .returns = void,
        });
        verifyFn(Window, "setAppearance", .{ .params = &.{ self_mut, bool }, .returns = void });
        verifyFn(Window, "setCursorShape", .{
            .params = &.{ self_mut, CursorShape },
            .returns = void,
        });
        verifyFn(Window, "getClearColor", .{
            .params = &.{self_const},
            .returns = geometry.Color,
        });

        verifyFn(Window, "getMousePosition", .{
            .params = &.{self_const},
            .returns = geometry.Point(f64),
        });
        verifyFn(Window, "isMouseInside", .{ .params = &.{self_const}, .returns = bool });
    }
}

/// Verify the calls the host loop and shutdown path make.
fn verifyWindowHostControl(comptime Window: type) void {
    comptime {
        verifyFn(Window, "requestRender", .{ .params = &.{*Window}, .returns = void });
        verifyFn(Window, "focus", .{ .params = &.{*Window}, .returns = void });
        verifyFn(Window, "close", .{ .params = &.{*Window}, .returns = void });
        verifyFn(Window, "isClosed", .{ .params = &.{*const Window}, .returns = bool });
    }
}

/// Verify the glass-style control that a `glass_effects` backend owes callers.
///
/// `capabilities.glass_effects` advertises that the host can composite a
/// translucent backdrop; `setGlassStyle` is how a caller selects which one.
/// `src/cx.zig` and `src/examples/glass.zig` each gate on the flag and then
/// call the method, so setting the flag already obliged a backend to declare
/// it — the obligation was simply unchecked, and a signature drift there would
/// have surfaced as an error inside an example rather than at the boundary.
///
/// Conditional rather than unconditional because Wayland has no portable blur
/// protocol: Linux has no style to select and declares no such method, and
/// demanding one would force a stub that lies. Gating a check on a comptime
/// backend property is the same shape as the `drive_model`-conditional
/// `isRunning` check in `verifyBackend`.
fn verifyGlassStyleControl(comptime Platform: type, comptime Window: type) void {
    comptime {
        if (!Platform.capabilities.glass_effects) return;

        // `f64` throughout, matching `WindowOptions.background_opacity` and
        // `glass_corner_radius`: the values come straight from those fields on
        // the native path, and an `f32` parameter would silently narrow them.
        verifyFn(Window, "setGlassStyle", .{
            .params = &.{ *Window, GlassStyle, f64, f64 },
            .returns = void,
        });
    }
}

/// Verify scene and atlas publication.
///
/// Still scene-pointer based; the immutable `PlatformFrame` handoff is phase 5
/// of the design doc.
fn verifyFrameHandoff(comptime Window: type) void {
    comptime {
        const self_mut: type = *Window;

        verifyFn(Window, "setScene", .{
            .params = &.{ self_mut, *const scene_mod.Scene },
            .returns = void,
        });
        verifyFn(Window, "setTextAtlas", .{
            .params = &.{ self_mut, *const text_mod.Atlas },
            .returns = void,
        });
        verifyFn(Window, "setSvgAtlas", .{
            .params = &.{ self_mut, *const text_mod.Atlas },
            .returns = void,
        });
        verifyFn(Window, "setImageAtlas", .{
            .params = &.{ self_mut, *const text_mod.Atlas },
            .returns = void,
        });
    }
}

/// Verify the IME composition bridge.
fn verifyImeBridge(comptime Window: type) void {
    comptime {
        const self_mut: type = *Window;

        verifyFn(Window, "setMarkedText", .{
            .params = &.{ self_mut, []const u8 },
            .returns = void,
        });
        verifyFn(Window, "clearMarkedText", .{ .params = &.{self_mut}, .returns = void });
        verifyFn(Window, "setInsertedText", .{
            .params = &.{ self_mut, []const u8 },
            .returns = void,
        });
        verifyFn(Window, "hasMarkedText", .{
            .params = &.{*const Window},
            .returns = bool,
        });
        verifyFn(Window, "setImeCursorRect", .{
            .params = &.{ self_mut, f32, f32, f32, f32 },
            .returns = void,
        });
    }
}

/// Verify the callback types and their setters.
///
/// Setters take optionals on every backend so `null` can clear a callback.
/// macOS previously took them non-optional and web took `anytype`, meaning
/// `WindowContext.setupWindow` compiled against three different contracts.
fn verifyCallbacks(comptime Window: type) void {
    comptime {
        const self_mut: type = *Window;

        verifyType(Window, "InputCallback", *const fn (*Window, input.InputEvent) bool);
        verifyType(Window, "RenderCallback", *const fn (*Window) void);
        verifyType(Window, "CloseCallback", *const fn (*Window) bool);
        verifyType(Window, "ResizeCallback", *const fn (*Window, f64, f64) void);
        verifyType(Window, "PostInputCallback", *const fn (*Window) void);

        verifyFn(Window, "setInputCallback", .{
            .params = &.{ self_mut, ?Window.InputCallback },
            .returns = void,
        });
        verifyFn(Window, "setRenderCallback", .{
            .params = &.{ self_mut, ?Window.RenderCallback },
            .returns = void,
        });
        verifyFn(Window, "setCloseCallback", .{
            .params = &.{ self_mut, ?Window.CloseCallback },
            .returns = void,
        });
        verifyFn(Window, "setResizeCallback", .{
            .params = &.{ self_mut, ?Window.ResizeCallback },
            .returns = void,
        });
        verifyFn(Window, "setPostInputCallback", .{
            .params = &.{ self_mut, ?Window.PostInputCallback },
            .returns = void,
        });

        verifyFn(Window, "setUserData", .{
            .params = &.{ self_mut, ?*anyopaque },
            .returns = void,
        });

        verifyUserDataRecovery(Window);
    }
}

/// Probe type used to instantiate a backend's generic `getUserData`.
///
/// Non-zero-sized and naturally aligned, because backends assert both before
/// casting. Its identity is the whole point: a backend that hands back
/// `?*UserDataProbe` has proved the cast preserves the *caller's* type rather
/// than erasing or wrapping it.
const UserDataProbe = struct { tag: u32 };

/// Verify `getUserData(self: *Self, comptime T: type) ?*T` exactly.
///
/// `verifyFn` cannot describe this declaration: a `comptime T: type` parameter
/// makes the `fn` type generic, so `@typeInfo` reports `return_type = null`
/// and there is no concrete signature to compare. That previously left the
/// declaration checked by a bare `@hasDecl` — the weakest possible check on
/// the one method all five static callbacks recover their context through, so
/// a backend returning `?T`, `*T`, or `?*anyopaque` would miscompile at the
/// call site instead of failing the contract.
///
/// The generic is instead *instantiated* here at `UserDataProbe` and the
/// resulting type compared exactly. `@TypeOf` analyzes the call for its type
/// only and generates no code, so the `undefined` receiver is never read; it
/// exists solely to make the call expression well-formed. This closes the
/// hole with no backend change, which is why no non-generic
/// `getUserDataOpaque` companion is required.
fn verifyUserDataRecovery(comptime Window: type) void {
    comptime {
        if (!@hasDecl(Window, "getUserData")) {
            @compileError(@typeName(Window) ++
                " is missing 'getUserData(self: *Self, comptime T: type) ?*T'");
        }

        const info = switch (@typeInfo(@TypeOf(@field(Window, "getUserData")))) {
            .@"fn" => |f| f,
            else => @compileError(@typeName(Window) ++ ".getUserData must be a function"),
        };

        if (info.params.len != 2) {
            @compileError(std.fmt.comptimePrint(
                "{s}.getUserData takes {d} parameter(s), expected 2:" ++
                    " (self: *Self, comptime T: type)",
                .{ @typeName(Window), info.params.len },
            ));
        }

        const Receiver = info.params[0].type orelse @compileError(std.fmt.comptimePrint(
            "{s}.getUserData has no concrete receiver type",
            .{@typeName(Window)},
        ));
        if (Receiver != *Window) {
            @compileError(std.fmt.comptimePrint(
                "{s}.getUserData receiver is {s}, expected {s}",
                .{ @typeName(Window), @typeName(Receiver), @typeName(*Window) },
            ));
        }

        // Checked before instantiating, so a non-type second parameter fails
        // with this message rather than an argument-coercion error inside the
        // `@TypeOf` below.
        if (info.params[1].type != type) {
            @compileError(std.fmt.comptimePrint(
                "{s}.getUserData parameter 1 must be 'comptime T: type'",
                .{@typeName(Window)},
            ));
        }

        const Recovered = @TypeOf(@field(Window, "getUserData")(
            @as(*Window, undefined),
            UserDataProbe,
        ));
        if (Recovered != ?*UserDataProbe) {
            @compileError(std.fmt.comptimePrint(
                "{s}.getUserData(T) returns {s}, expected {s}",
                .{ @typeName(Window), @typeName(Recovered), @typeName(?*UserDataProbe) },
            ));
        }
    }
}

// =============================================================================
// Backend contract
// =============================================================================

/// Verify a complete backend namespace.
///
/// A backend namespace must expose `Platform`, `PlatformWindow`, and
/// `drive_model`. `mod.zig` derives its public aliases from exactly these, so
/// backends no longer invent parallel names.
pub fn verifyBackend(comptime Backend: type) void {
    comptime {
        if (!@hasDecl(Backend, "Platform")) {
            @compileError(@typeName(Backend) ++ " must declare 'Platform'");
        }
        if (!@hasDecl(Backend, "PlatformWindow")) {
            @compileError(@typeName(Backend) ++ " must declare 'PlatformWindow'");
        }

        verifyConst(Backend, "drive_model", DriveModel);

        verifyPlatform(Backend.Platform);
        verifyPlatformWindow(Backend.Platform, Backend.PlatformWindow);

        // A `host_callback` backend returns from `run` immediately, so it must
        // be able to report liveness for the host to keep rescheduling. The
        // required meaning is documented on the `verifyPlatform` check; this
        // re-verification exists so the declaration cannot be dropped from a
        // backend whose host depends on it.
        if (Backend.drive_model == .host_callback) {
            verifyFn(Backend.Platform, "isRunning", .{
                .params = &.{*const Backend.Platform},
                .returns = bool,
            });
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;

/// Minimal well-formed fixture used to prove the verifier accepts a correct
/// shape. Kept deliberately tiny: the full fixed-capacity reference backend
/// lives in `src/testing/test_backend.zig`.
const GoodPlatform = struct {
    allocator: std.mem.Allocator = undefined,
    running: bool = false,
    registry: interface.WindowRegistry = undefined,
    loop_turn_callback: ?LoopTurnCallback = null,

    pub const capabilities = PlatformCapabilities{ .name = "contract-fixture" };

    pub const LoopTurnCallback = *const fn (*@This()) void;

    pub fn initInPlace(self: *@This(), allocator: std.mem.Allocator) !void {
        self.allocator = allocator;
        self.running = false;
        self.registry = interface.WindowRegistry.init(allocator);
        self.loop_turn_callback = null;
    }
    pub fn deinit(self: *@This()) void {
        self.registry.deinit();
    }
    pub fn run(self: *@This()) void {
        self.running = true;
    }
    pub fn quit(self: *@This()) void {
        self.running = false;
    }
    pub fn isRunning(self: *const @This()) bool {
        return self.running;
    }
    pub fn registerWindow(self: *@This(), window: *anyopaque) !WindowId {
        return self.registry.register(window);
    }
    pub fn unregisterWindow(self: *@This(), id: WindowId) void {
        _ = self.registry.unregister(id);
    }
    pub fn getWindow(self: *const @This(), id: WindowId) ?*anyopaque {
        return self.registry.get(id);
    }
    pub fn getActiveWindowId(self: *const @This()) ?WindowId {
        return self.registry.getActiveWindow();
    }
    pub fn setActiveWindowId(self: *@This(), id: ?WindowId) void {
        self.registry.setActiveWindow(id);
    }
    pub fn windowCount(self: *const @This()) u32 {
        return self.registry.count();
    }
    pub fn setLoopTurnCallback(self: *@This(), callback: ?LoopTurnCallback) void {
        self.loop_turn_callback = callback;
    }
};

test "verifyPlatform accepts a conforming fixture" {
    comptime verifyPlatform(GoodPlatform);
}

test "verifyFn matches an exact signature" {
    const Fixture = struct {
        pub fn takesSlice(_: *@This(), _: []const u8) u32 {
            return 0;
        }
    };
    comptime verifyFn(Fixture, "takesSlice", .{
        .params = &.{ *Fixture, []const u8 },
        .returns = u32,
    });
}

test "verifyFn accepts an inferred error set as a required error union" {
    // Backends universally use inferred error sets, so the payload — not the
    // error set — is what the verifier may compare.
    const Fixture = struct {
        pub fn fallible(_: *@This()) !u16 {
            return 7;
        }
    };
    comptime verifyFn(Fixture, "fallible", .{
        .params = &.{*Fixture},
        .returns = u16,
        .errors = .required,
    });
}

test "verifyConst matches a comptime declaration type" {
    const Fixture = struct {
        pub const drive_model: DriveModel = .host_callback;
    };
    comptime verifyConst(Fixture, "drive_model", DriveModel);
}

test "verifyType matches an exact type declaration" {
    const Fixture = struct {
        pub const Callback = *const fn (u8) void;
    };
    comptime verifyType(Fixture, "Callback", *const fn (u8) void);
}

test "verifyField matches a field's declared type" {
    // Goal: prove the field checker reads `struct.fields`, so the two
    // geometry fields shared code touches directly are pinned by name *and*
    // type. Method: a fixture carrying exactly those fields, verified
    // alongside a getter to show declarations and fields are read separately.
    const Fixture = struct {
        size: geometry.Size(f64) = .{ .width = 0, .height = 0 },
        scale_factor: f64 = 1.0,

        pub fn getScaleFactor(self: *const @This()) f64 {
            return self.scale_factor;
        }
    };
    comptime verifyField(Fixture, "size", geometry.Size(f64));
    comptime verifyField(Fixture, "scale_factor", f64);
    comptime verifyFn(Fixture, "getScaleFactor", .{
        .params = &.{*const Fixture},
        .returns = f64,
    });
}

test "verifyUserDataRecovery instantiates the generic getter exactly" {
    // Goal: the generic `getUserData` is checked by instantiation, not by
    // presence. Method: a fixture with the production shape must pass, and
    // the recovered type must be the probe pointer rather than an erased or
    // unwrapped variant.
    const Fixture = struct {
        user_data: ?*anyopaque = null,

        pub fn getUserData(self: *@This(), comptime T: type) ?*T {
            if (self.user_data) |ptr| return @ptrCast(@alignCast(ptr));
            return null;
        }
    };
    comptime verifyUserDataRecovery(Fixture);

    const Recovered = @TypeOf(Fixture.getUserData(@as(*Fixture, undefined), UserDataProbe));
    try testing.expect(Recovered == ?*UserDataProbe);
    try testing.expect(@sizeOf(UserDataProbe) > 0);
}

test "describe renders a readable signature" {
    const rendered = comptime describe(.{
        .params = &.{ *GoodPlatform, std.mem.Allocator },
        .returns = void,
        .errors = .required,
    });
    // The parameter type names are fully qualified, so assert on the shape
    // rather than the exact prefix.
    try testing.expect(std.mem.startsWith(u8, rendered, "fn ("));
    try testing.expect(std.mem.endsWith(u8, rendered, ") !void"));
    try testing.expect(std.mem.indexOf(u8, rendered, "Allocator") != null);
}

test "production backend satisfies the platform contract" {
    // This is the check that previously did not exist: the backend selected for
    // this target is verified against the full contract rather than two names.
    const platform_mod = @import("mod.zig");
    comptime verifyBackend(platform_mod.backend);
    _ = builtin;
}
