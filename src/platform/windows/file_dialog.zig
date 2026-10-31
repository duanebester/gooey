//! Windows file dialogs through the Common Item Dialog (`IFileOpenDialog`,
//! `IFileSaveDialog`), the dialog Explorer and every current Windows
//! application use.
//!
//! The API matches `macos/file_dialog.zig` and `linux/file_dialog.zig`:
//! `promptForPaths` and `promptForNewPath` block until the user chooses or
//! cancels, and return caller-owned paths or null.
//!
//! ## Behaviour
//!
//! - **Modality.** The dialog is owned by the thread's active window, which
//!   Windows disables while it is shown. The dialog runs its own message loop,
//!   so Gooey windows still receive `WM_PAINT` and redraw, but the platform
//!   loop does not turn. Call it from a deferred command (`cx.deferCommand`),
//!   not from inside an input handler.
//! - **Directories.** `directories = true` picks folders only, as on Linux:
//!   the Common Item Dialog cannot offer files and folders together.
//! - **Paths.** Returned paths are WTF-8, the encoding Zig's file APIs take on
//!   Windows, so a name with an unpaired surrogate still opens. Input paths
//!   and the suggested name are read as WTF-8, a superset of UTF-8.
//! - **Working directory.** `FOS_NOCHANGEDIR` keeps the dialog from changing
//!   the process's working directory, which examples use to find `assets/`.
//! - **New folders.** The dialog always offers "New folder", as the shared
//!   options promise (contract decision 11).
//!
//! ## COM
//!
//! The dialog is an apartment-threaded COM object. Each call enters a
//! single-threaded apartment and balances the entry. A thread already in the
//! multithreaded apartment (`RPC_E_CHANGED_MODE`) keeps it; COM then hosts the
//! dialog in an apartment of its own.
//!
//! ## Allocation and bounds (CLAUDE.md sections 2 and 4)
//!
//! The shared contract returns heap paths owned by the caller, as on every
//! backend, which conflicts with section 2; replacing it with bounded request
//! slots is phase 6 of `docs/platform_interface_design.md`. Everything else is
//! fixed and on the stack, at most about 65 KiB per call:
//!
//! - The suggested file name: `text_units_max + 1` units, about 1 KiB, alive
//!   until the dialog is released.
//! - The save dialog's folder: `path_units_max + 1` units, 64 KiB, in one leaf.
//! - Results: at most `path_count_max` paths of at most `path_units_max`
//!   units each. A longer path or a larger selection is refused, never
//!   truncated. The result is at most 1,024 × 98,301 B in the worst case;
//!   ordinary paths are below 260 units.
//!
//! The shell allocates its own strings (`GetDisplayName`), freed here with
//! `CoTaskMemFree` on every path.

const std = @import("std");
const interface_mod = @import("../interface.zig");
const shell = @import("shell.zig");
const win32 = @import("win32.zig");

const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const PathPromptOptions = interface_mod.PathPromptOptions;
pub const PathPromptResult = interface_mod.PathPromptResult;
pub const SavePromptOptions = interface_mod.SavePromptOptions;

/// Longest suggested file name, in UTF-16 units excluding the terminator.
pub const text_units_max: u32 = 512;

/// Longest path, in UTF-16 units excluding the terminator: Windows' limit
/// for extended-length paths.
pub const path_units_max: u32 = 32_767;

/// Most paths one open dialog may return.
pub const path_count_max: u32 = 1_024;

const DialogError = error{
    Cancelled,
    ComFailed,
    OptionInvalid,
    OptionTooLong,
    OutOfMemory,
    PathTooLong,
    SelectionEmpty,
    TooManyPaths,
};

/// Whether `comEnter` initialized COM on this thread, so `comLeave` must
/// balance it.
const Apartment = enum { entered, foreign };

comptime {
    // WTF-8 needs at most three bytes per UTF-16 unit.
    assert(@as(u64, path_units_max) * 3 < std.math.maxInt(u32));
    assert(text_units_max < path_units_max);
}

// =============================================================================
// Open dialog
// =============================================================================

/// Show a file or folder open dialog (blocking, modal). Returns null if the
/// user cancels or on error. The caller owns the result and calls `deinit`.
pub fn promptForPaths(allocator: Allocator, options: PathPromptOptions) ?PathPromptResult {
    assert(options.files or options.directories);

    const apartment = comEnter();
    defer comLeave(apartment);

    const open = dialogCreate(
        shell.IFileOpenDialog,
        &shell.CLSID_FileOpenDialog,
        &shell.IID_IFileOpenDialog,
    ) orelse return null;
    defer open.dialog().release();

    openConfigure(open.dialog(), &options) catch |err| {
        dialogFailed("open", err);
        return null;
    };
    dialogShow(open.dialog()) catch |err| {
        dialogFailed("open", err);
        return null;
    };
    const result = openResults(allocator, open) catch |err| {
        dialogFailed("open", err);
        return null;
    };
    assert(result.paths.len > 0);
    assert(result.paths.len <= path_count_max);
    return result;
}

fn openConfigure(dialog: *shell.IFileDialog, options: *const PathPromptOptions) DialogError!void {
    assert(options.files or options.directories);

    var flags_default: u32 = 0;
    try comChecked(dialog.vtable.GetOptions(dialog, &flags_default), "GetOptions");
    const flags = openFlags(flags_default, options);
    try comChecked(dialog.vtable.SetOptions(dialog, flags), "SetOptions");
}

/// The dialog's default options plus Gooey's: file system items only, the
/// working directory left alone, and the selection kind and count asked for.
fn openFlags(flags_default: u32, options: *const PathPromptOptions) u32 {
    assert(options.files or options.directories);
    var flags = flags_default | shell.FOS_FORCEFILESYSTEM | shell.FOS_NOCHANGEDIR |
        shell.FOS_PATHMUSTEXIST;
    if (options.directories) {
        flags |= shell.FOS_PICKFOLDERS;
    } else {
        flags |= shell.FOS_FILEMUSTEXIST;
    }
    if (options.multiple) {
        flags |= shell.FOS_ALLOWMULTISELECT;
    } else {
        flags &= ~shell.FOS_ALLOWMULTISELECT;
    }
    assert(flags & shell.FOS_FORCEFILESYSTEM != 0);
    assert(flags & shell.FOS_NOCHANGEDIR != 0);
    return flags;
}

fn openResults(allocator: Allocator, open: *shell.IFileOpenDialog) DialogError!PathPromptResult {
    var items_result: ?*shell.IShellItemArray = null;
    try comChecked(open.vtable.GetResults(open, &items_result), "GetResults");
    assert(items_result != null); // COM: success returns an interface.
    const items = items_result.?;
    defer items.release();

    var count: u32 = 0;
    try comChecked(items.vtable.GetCount(items, &count), "GetCount");
    if (count == 0) return error.SelectionEmpty;
    if (count <= path_count_max) {
        // Within the bound; collected below.
    } else {
        std.log.warn("windows: {d} paths selected exceed {d}; refused", .{
            count,
            path_count_max,
        });
        return error.TooManyPaths;
    }

    const paths = try allocator.alloc([]const u8, count);
    errdefer allocator.free(paths);

    var filled: u32 = 0;
    errdefer for (paths[0..filled]) |path| allocator.free(path);
    while (filled < count) : (filled += 1) {
        paths[filled] = try arrayItemPath(allocator, items, filled);
    }
    assert(filled == count);
    return .{ .paths = paths, .allocator = allocator };
}

fn arrayItemPath(
    allocator: Allocator,
    items: *shell.IShellItemArray,
    index: u32,
) DialogError![]const u8 {
    assert(index < path_count_max);
    var item_result: ?*shell.IShellItem = null;
    try comChecked(items.vtable.GetItemAt(items, index, &item_result), "GetItemAt");
    assert(item_result != null); // COM: success returns an interface.
    const item = item_result.?;
    defer item.release();

    return itemPath(allocator, item);
}

// =============================================================================
// Save dialog
// =============================================================================

/// Show a file save dialog (blocking, modal). Returns null if the user
/// cancels or on error. The caller owns the path and frees it with
/// `allocator`.
pub fn promptForNewPath(allocator: Allocator, options: SavePromptOptions) ?[]const u8 {
    if (options.suggested_name) |name| assert(name.len > 0);
    if (options.directory) |directory| assert(directory.len > 0);

    const apartment = comEnter();
    defer comLeave(apartment);

    const save = dialogCreate(
        shell.IFileSaveDialog,
        &shell.CLSID_FileSaveDialog,
        &shell.IID_IFileSaveDialog,
    ) orelse return null;
    defer save.dialog().release();

    var file_name: [text_units_max + 1]u16 = undefined;
    saveConfigure(save.dialog(), &options, &file_name) catch |err| {
        dialogFailed("save", err);
        return null;
    };
    dialogShow(save.dialog()) catch |err| {
        dialogFailed("save", err);
        return null;
    };
    const path = savePath(allocator, save.dialog()) catch |err| {
        dialogFailed("save", err);
        return null;
    };
    assert(std.unicode.wtf8ValidateSlice(path));
    return path;
}

/// `file_name` holds the suggested name's UTF-16 copy and stays in the
/// caller's frame until the dialog is released, so correctness does not
/// depend on whether the dialog copies it.
fn saveConfigure(
    dialog: *shell.IFileDialog,
    options: *const SavePromptOptions,
    file_name: *[text_units_max + 1]u16,
) DialogError!void {
    var flags_default: u32 = 0;
    try comChecked(dialog.vtable.GetOptions(dialog, &flags_default), "GetOptions");
    try comChecked(dialog.vtable.SetOptions(dialog, saveFlags(flags_default)), "SetOptions");

    if (options.suggested_name) |name| {
        assert(name.len > 0);
        const wide = try wideEncode(file_name, name);
        assert(wide.len <= text_units_max);
        try comChecked(dialog.vtable.SetFileName(dialog, wide), "SetFileName");
    }
    if (options.directory) |directory| {
        try dialogFolderSet(dialog, directory);
    }
}

/// The dialog's default options plus Gooey's: file system items only, the
/// working directory left alone, and a prompt before overwriting.
fn saveFlags(flags_default: u32) u32 {
    const flags = flags_default | shell.FOS_FORCEFILESYSTEM | shell.FOS_NOCHANGEDIR |
        shell.FOS_PATHMUSTEXIST | shell.FOS_OVERWRITEPROMPT;
    assert(flags & shell.FOS_PICKFOLDERS == flags_default & shell.FOS_PICKFOLDERS);
    assert(flags & shell.FOS_OVERWRITEPROMPT != 0);
    return flags;
}

fn savePath(allocator: Allocator, dialog: *shell.IFileDialog) DialogError![]const u8 {
    var item_result: ?*shell.IShellItem = null;
    try comChecked(dialog.vtable.GetResult(dialog, &item_result), "GetResult");
    assert(item_result != null); // COM: success returns an interface.
    const item = item_result.?;
    defer item.release();

    return itemPath(allocator, item);
}

// =============================================================================
// Shared dialog steps
// =============================================================================

fn comEnter() Apartment {
    const result = shell.CoInitializeEx(
        null,
        shell.COINIT_APARTMENTTHREADED | shell.COINIT_DISABLE_OLE1DDE,
    );
    if (shell.succeeded(result)) {
        assert(result == shell.S_OK or result == shell.S_FALSE);
        return .entered;
    }
    // `RPC_E_CHANGED_MODE` leaves COM usable in the thread's existing
    // apartment. Any other failure surfaces when the dialog is created.
    if (result != shell.RPC_E_CHANGED_MODE) {
        std.log.warn("windows: CoInitializeEx failed (HRESULT 0x{X:0>8})", .{
            hresultBits(result),
        });
    }
    return .foreign;
}

fn comLeave(apartment: Apartment) void {
    if (apartment == .entered) shell.CoUninitialize();
}

fn dialogCreate(
    comptime Dialog: type,
    class: *const shell.GUID,
    interface: *const shell.GUID,
) ?*Dialog {
    comptime assert(@hasDecl(Dialog, "dialog"));
    var object: ?*anyopaque = null;
    const result = shell.CoCreateInstance(
        class,
        null,
        shell.CLSCTX_INPROC_SERVER,
        interface,
        &object,
    );
    if (shell.succeeded(result)) {
        assert(object != null); // COM: success returns an interface.
        return @ptrCast(@alignCast(object.?));
    }
    std.log.warn("windows: file dialog creation failed (HRESULT 0x{X:0>8})", .{
        hresultBits(result),
    });
    return null;
}

/// Show the dialog, owned by the thread's active window so it is modal to
/// it. With no active window the dialog is unowned.
fn dialogShow(dialog: *shell.IFileDialog) DialogError!void {
    const owner = win32.GetActiveWindow();
    const result = dialog.vtable.Show(dialog, owner);
    if (result == shell.HRESULT_ERROR_CANCELLED) return error.Cancelled;
    try comChecked(result, "Show");
}

/// Open the dialog in `directory`. A folder the shell cannot resolve is not
/// an error: the dialog opens where it would have without the option.
fn dialogFolderSet(dialog: *shell.IFileDialog, directory: []const u8) DialogError!void {
    var buffer: [path_units_max + 1]u16 = undefined;
    const path = try wideEncode(&buffer, directory);
    assert(path.len <= path_units_max);

    var object: ?*anyopaque = null;
    const result = shell.SHCreateItemFromParsingName(path, null, &shell.IID_IShellItem, &object);
    if (shell.succeeded(result)) {
        assert(object != null); // COM: success returns an interface.
        const folder: *shell.IShellItem = @ptrCast(@alignCast(object.?));
        defer folder.release();
        try comChecked(dialog.vtable.SetFolder(dialog, folder), "SetFolder");
    } else {
        std.log.warn("windows: file dialog folder unresolved (HRESULT 0x{X:0>8}); ignored", .{
            hresultBits(result),
        });
    }
}

/// A caller-owned WTF-8 copy of the item's file system path.
fn itemPath(allocator: Allocator, item: *shell.IShellItem) DialogError![]const u8 {
    var name_result: ?[*:0]u16 = null;
    const result = item.vtable.GetDisplayName(item, shell.SIGDN_FILESYSPATH, &name_result);
    try comChecked(result, "GetDisplayName");
    assert(name_result != null); // COM: success returns a string.
    const name = name_result.?;
    defer shell.CoTaskMemFree(name);

    const units = unitsTerminated(name, path_units_max) orelse {
        std.log.warn("windows: selected path exceeds {d} units; refused", .{path_units_max});
        return error.PathTooLong;
    };
    return pathDecode(allocator, units);
}

fn comChecked(result: shell.HRESULT, method: []const u8) DialogError!void {
    assert(method.len > 0);
    if (shell.succeeded(result)) return;
    std.log.warn("windows: file dialog {s} failed (HRESULT 0x{X:0>8})", .{
        method,
        hresultBits(result),
    });
    return error.ComFailed;
}

fn dialogFailed(kind: []const u8, err: DialogError) void {
    assert(kind.len > 0);
    switch (err) {
        error.Cancelled => {}, // The user's choice, not a failure.
        else => std.log.warn("windows: {s} dialog failed: {s}", .{ kind, @errorName(err) }),
    }
}

fn hresultBits(result: shell.HRESULT) u32 {
    return @bitCast(result);
}

// =============================================================================
// Encoding: WTF-8 to terminated UTF-16 and back
// =============================================================================

/// Encode `text` into `target` with a terminating zero. Fails when `text` is
/// not WTF-8, holds a zero byte, or does not fit with its terminator.
fn wideEncode(target: []u16, text: []const u8) DialogError![:0]const u16 {
    assert(target.len > 0);
    const count = try wideAppend(target, 0, text);
    return wideTerminate(target, count);
}

/// Append `text` to the `count` units already in `target`. Returns the new
/// count.
fn wideAppend(target: []u16, count: usize, text: []const u8) DialogError!usize {
    assert(count <= target.len);
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.OptionInvalid;
    const unit_count = std.unicode.calcWtf16LeLen(text) catch return error.OptionInvalid;
    if (unit_count <= target.len - count) {
        // `calcWtf16LeLen` validated `text`, so encoding cannot fail.
        const written = std.unicode.wtf8ToWtf16Le(target[count..][0..unit_count], text) catch
            unreachable;
        assert(written == unit_count);
        return count + unit_count;
    }
    return error.OptionTooLong;
}

fn wideTerminate(target: []u16, count: usize) DialogError![:0]const u16 {
    assert(count <= target.len);
    if (count < target.len) {
        target[count] = 0;
        return target[0..count :0];
    }
    return error.OptionTooLong;
}

/// The units before the terminator, examining at most `unit_count_max + 1`
/// units, or null when there are more than `unit_count_max`.
fn unitsTerminated(units: [*:0]const u16, unit_count_max: u32) ?[]const u16 {
    var index: u32 = 0;
    while (index <= unit_count_max) : (index += 1) {
        if (units[index] == 0) return units[0..index];
    }
    assert(index == unit_count_max + 1);
    return null;
}

/// A caller-owned WTF-8 copy of `units`.
fn pathDecode(allocator: Allocator, units: []const u16) DialogError![]const u8 {
    assert(units.len <= path_units_max);
    const byte_count = std.unicode.calcWtf8Len(units);
    assert(byte_count <= 3 * units.len);

    const path = try allocator.alloc(u8, byte_count);
    const written = std.unicode.wtf16LeToWtf8(path, units);
    assert(written == byte_count);
    assert(std.unicode.wtf8ValidateSlice(path));
    return path;
}

// =============================================================================
// Tests
// =============================================================================

const testing = std.testing;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "wideEncode fills to capacity and refuses one unit more or invalid text" {
    // Capacity test: a buffer of four units holds three and the terminator.
    var buffer: [4]u16 = undefined;
    try testing.expectEqualSlices(u16, L("abc"), try wideEncode(&buffer, "abc"));
    try testing.expectEqual(@as(u16, 0), buffer[3]);
    try testing.expectError(error.OptionTooLong, wideEncode(&buffer, "abcd"));
    try testing.expectEqualSlices(u16, L(""), try wideEncode(&buffer, ""));

    // A scalar outside the BMP takes two units; U+00E9 takes one.
    const mixed = "\u{1F389}\u{E9}";
    try testing.expectEqualSlices(u16, L(mixed), try wideEncode(&buffer, mixed));
    try testing.expectError(error.OptionTooLong, wideEncode(&buffer, "\u{1F389}\u{1F389}"));

    try testing.expectError(error.OptionInvalid, wideEncode(&buffer, "\xFF"));
    try testing.expectError(error.OptionInvalid, wideEncode(&buffer, "a\x00b"));
}

test "openFlags selects the kind and count and keeps the dialog defaults" {
    const flags_default = shell.FOS_PATHMUSTEXIST | shell.FOS_FILEMUSTEXIST;
    const files = openFlags(flags_default, &.{
        .files = true,
        .directories = false,
        .multiple = true,
    });
    try testing.expect(files & shell.FOS_ALLOWMULTISELECT != 0);
    try testing.expect(files & shell.FOS_PICKFOLDERS == 0);
    try testing.expect(files & shell.FOS_FORCEFILESYSTEM != 0);
    try testing.expect(files & shell.FOS_NOCHANGEDIR != 0);

    const folders = openFlags(0, &.{ .files = false, .directories = true, .multiple = false });
    try testing.expect(folders & shell.FOS_PICKFOLDERS != 0);
    try testing.expect(folders & shell.FOS_FILEMUSTEXIST == 0);

    // A default that allows several items is cleared for a single choice.
    const single = openFlags(shell.FOS_ALLOWMULTISELECT, &.{
        .files = true,
        .directories = false,
        .multiple = false,
    });
    try testing.expect(single & shell.FOS_ALLOWMULTISELECT == 0);

    const save = saveFlags(0);
    try testing.expect(save & shell.FOS_OVERWRITEPROMPT != 0);
    try testing.expect(save & shell.FOS_NOCHANGEDIR != 0);
}

test "unitsTerminated stops at the terminator and refuses one unit past the bound" {
    const exact = L("abcd");
    try testing.expectEqualSlices(u16, exact, unitsTerminated(exact, 4).?);
    try testing.expect(unitsTerminated(exact, 3) == null);
    try testing.expectEqual(@as(usize, 0), unitsTerminated(L(""), 0).?.len);
}

test "pathDecode yields WTF-8 that keeps an unpaired surrogate" {
    // Goal: NTFS names may hold unpaired surrogates; WTF-8 keeps them so the
    // path still opens through Zig's file APIs.
    const units = [_]u16{ 'C', ':', '\\', 0xD800, 'x', 0xD83C, 0xDF89 };
    const path = try pathDecode(testing.allocator, &units);
    defer testing.allocator.free(path);
    try testing.expectEqualSlices(u8, "C:\\\xED\xA0\x80x\u{1F389}", path);

    var round_trip: [units.len]u16 = undefined;
    const written = try std.unicode.wtf8ToWtf16Le(&round_trip, path);
    try testing.expectEqualSlices(u16, &units, round_trip[0..written]);
}

extern "kernel32" fn GetCurrentDirectoryW(
    nBufferLength: u32,
    lpBuffer: [*]u16,
) callconv(.winapi) u32;

/// The working directory as WTF-8, owned by the testing allocator.
fn testWorkingDirectory() ![]const u8 {
    var buffer: [path_units_max + 1]u16 = undefined;
    const count = GetCurrentDirectoryW(buffer.len, &buffer);
    if (count == 0) return error.NoWorkingDirectory;
    if (count >= buffer.len) return error.NoWorkingDirectory;
    return pathDecode(testing.allocator, buffer[0..count]);
}

test "system shell item round-trips the working directory" {
    // Methodology: the real shell parses the working directory into an
    // `IShellItem` and returns its file system path, which pins
    // `IID_IShellItem`, `GetDisplayName`'s slot, and the WTF-16 decoding.
    const apartment = comEnter();
    defer comLeave(apartment);

    const directory = try testWorkingDirectory();
    defer testing.allocator.free(directory);

    var buffer: [path_units_max + 1]u16 = undefined;
    const wide = try wideEncode(&buffer, directory);
    var object: ?*anyopaque = null;
    const result = shell.SHCreateItemFromParsingName(wide, null, &shell.IID_IShellItem, &object);
    try testing.expect(shell.succeeded(result));
    const item: *shell.IShellItem = @ptrCast(@alignCast(object.?));
    defer item.release();

    const path = try itemPath(testing.allocator, item);
    defer testing.allocator.free(path);
    try testing.expectEqualStrings(directory, path);
}

test "system open dialog accepts every option and fails cleanly before Show" {
    // Methodology: configure a real `IFileOpenDialog` with every option and
    // read its options back, without showing it. Asking for results before
    // `Show` exercises the COM failure path.
    const apartment = comEnter();
    defer comLeave(apartment);

    const open = dialogCreate(
        shell.IFileOpenDialog,
        &shell.CLSID_FileOpenDialog,
        &shell.IID_IFileOpenDialog,
    ) orelse return error.TestDialogCreation;
    defer open.dialog().release();

    const options: PathPromptOptions = .{ .files = true, .directories = false, .multiple = true };
    try openConfigure(open.dialog(), &options);

    var flags: u32 = 0;
    try comChecked(open.dialog().vtable.GetOptions(open.dialog(), &flags), "GetOptions");
    try testing.expect(flags & shell.FOS_ALLOWMULTISELECT != 0);
    try testing.expect(flags & shell.FOS_NOCHANGEDIR != 0);
    try testing.expect(flags & shell.FOS_PICKFOLDERS == 0);

    try testing.expectError(error.ComFailed, openResults(testing.allocator, open));
}

test "system save dialog accepts every option" {
    const apartment = comEnter();
    defer comLeave(apartment);

    const save = dialogCreate(
        shell.IFileSaveDialog,
        &shell.CLSID_FileSaveDialog,
        &shell.IID_IFileSaveDialog,
    ) orelse return error.TestDialogCreation;
    defer save.dialog().release();

    const options: SavePromptOptions = .{
        .suggested_name = "untitled \u{1F389}.txt",
        .directory = "Z:\\gooey\\no such folder", // Unresolved: logged and ignored.
    };
    var file_name: [text_units_max + 1]u16 = undefined;
    try saveConfigure(save.dialog(), &options, &file_name);

    var flags: u32 = 0;
    try comChecked(save.dialog().vtable.GetOptions(save.dialog(), &flags), "GetOptions");
    try testing.expect(flags & shell.FOS_OVERWRITEPROMPT != 0);
    try testing.expect(flags & shell.FOS_FORCEFILESYSTEM != 0);
}
