//! Web File Dialog - Async file selection via browser APIs
//!
//! Provides file open/save dialogs for WASM targets using:
//! - <input type="file"> for open dialogs
//! - Blob + download link for save dialogs
//!
//! Flow for openFiles:
//! 1. Zig calls requestFileDialog() with options
//! 2. JS creates/triggers hidden <input type="file">
//! 3. User selects file(s)
//! 4. JS reads file contents via FileReader
//! 5. JS allocates WASM memory and copies data
//! 6. JS calls onFileDialogComplete()
//! 7. Zig processes the selected files
//!
//! Flow for saveFile:
//! 1. Zig calls promptSaveFile() with filename + data
//! 2. JS creates Blob and download link
//! 3. Browser triggers download (fire-and-forget)
//!
//! Web Limitations:
//! - No access to full file paths (security)
//! - Save always goes to Downloads folder
//! - Directory selection only in Chrome (webkitdirectory)

const std = @import("std");
const imports = @import("imports.zig");
const interface_mod = @import("../../interface.zig");

// ============================================================================
// Types
// ============================================================================

/// A file selected from the dialog (web-specific: includes content)
pub const WebFile = struct {
    /// File name only (no path - browser security)
    name: []const u8,
    /// File contents
    content: []const u8,
    /// File size in bytes
    size: usize,

    /// We own this memory
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WebFile) void {
        self.allocator.free(self.name);
        self.allocator.free(self.content);
        self.* = undefined;
    }
};

/// Result from a file open dialog
pub const WebFileDialogResult = struct {
    /// Selected files with their contents
    files: []WebFile,
    /// Allocator used for cleanup
    allocator: std.mem.Allocator,

    pub fn deinit(self: *WebFileDialogResult) void {
        for (self.files) |*file| {
            file.deinit();
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

/// Options for open file dialog
pub const OpenDialogOptions = struct {
    /// Accept filter (e.g., ".txt,.md,.zig" or "image/*")
    accept: ?[]const u8 = null,
    /// Allow multiple file selection
    multiple: bool = false,
    /// Allow directory selection (Chrome only)
    directories: bool = false,
};

/// Callback type for async file dialog
pub const FileDialogCallback = *const fn (request_id: u32, result: ?WebFileDialogResult) void;

// ============================================================================
// Internal State
// ============================================================================

/// Pending dialog request
const PendingDialog = struct {
    callback: FileDialogCallback,
    /// Accumulated files during multi-file selection
    files: std.ArrayList(WebFile),
    expected_count: u32,
    received_count: u32,
};

var pending_requests: std.AutoHashMap(u32, PendingDialog) = undefined;
var next_request_id: u32 = 1;
var initialized: bool = false;
var global_allocator: std.mem.Allocator = undefined;

// ============================================================================
// Public API
// ============================================================================

/// Initialize the file dialog system
pub fn init(allocator: std.mem.Allocator) void {
    if (initialized) return;
    global_allocator = allocator;
    pending_requests = std.AutoHashMap(u32, PendingDialog).init(allocator);
    initialized = true;
}

/// Deinitialize and free resources
pub fn deinit() void {
    if (!initialized) return;

    // Clean up any pending requests
    var it = pending_requests.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.files.items) |*file| {
            file.deinit();
        }
        entry.value_ptr.files.deinit(global_allocator);
    }

    pending_requests.deinit();
    initialized = false;
}

/// Open a file dialog asynchronously.
/// The callback will be invoked when the user selects files or cancels.
/// Returns the request_id for tracking, or null on failure.
pub fn openFilesAsync(
    options: OpenDialogOptions,
    callback: FileDialogCallback,
) ?u32 {
    if (!initialized) {
        imports.err("file_dialog: not initialized", .{});
        return null;
    }

    const request_id = next_request_id;
    next_request_id +%= 1;

    pending_requests.put(request_id, .{
        .callback = callback,
        .files = .{},
        .expected_count = 0,
        .received_count = 0,
    }) catch {
        imports.err("file_dialog: failed to track request {}", .{request_id});
        return null;
    };

    // Build accept string
    const accept_ptr: [*]const u8 = if (options.accept) |a| a.ptr else undefined;
    const accept_len: u32 = if (options.accept) |a| @intCast(a.len) else 0;

    // Call into JavaScript
    imports.requestFileDialog(
        request_id,
        accept_ptr,
        accept_len,
        options.multiple,
        options.directories,
    );

    return request_id;
}

/// Trigger a file download (web "save" dialog).
/// This is fire-and-forget - the browser handles the download.
/// The user will see a download prompt or the file goes to Downloads.
pub fn saveFile(
    filename: []const u8,
    data: []const u8,
) void {
    imports.promptSaveFile(
        filename.ptr,
        @intCast(filename.len),
        data.ptr,
        @intCast(data.len),
    );
}

/// Cancel a pending dialog request
pub fn cancelRequest(request_id: u32) void {
    if (pending_requests.fetchRemove(request_id)) |kv| {
        for (kv.value.files.items) |*file| {
            file.deinit();
        }
        var files = kv.value.files;
        files.deinit(global_allocator);
    }
}

/// Check if a request is still pending
pub fn isPending(request_id: u32) bool {
    return pending_requests.contains(request_id);
}

// ============================================================================
// WASM Exports (called from JavaScript)
// ============================================================================

/// Called by JS when user cancels the dialog or selects 0 files
export fn onFileDialogCancelled(request_id: u32) void {
    const kv = pending_requests.fetchRemove(request_id);
    if (kv == null) return;

    var entry = kv.?.value;
    entry.files.deinit(global_allocator);
    entry.callback(request_id, null);
}

/// Called by JS to report how many files were selected
/// This prepares us to receive that many onFileDialogFile calls
export fn onFileDialogStart(request_id: u32, file_count: u32) void {
    if (pending_requests.getPtr(request_id)) |pending| {
        pending.expected_count = file_count;
        pending.received_count = 0;

        // If 0 files, treat as cancel
        if (file_count == 0) {
            onFileDialogCancelled(request_id);
        }
    }
}

/// Called by JS for each file, providing name and content
export fn onFileDialogFile(
    request_id: u32,
    name_ptr: u32,
    name_len: u32,
    content_ptr: u32,
    content_len: u32,
) void {
    const pending = pending_requests.getPtr(request_id);
    if (pending == null) {
        // Request was cancelled, free the memory
        if (name_ptr != 0) wasmFree(name_ptr, name_len);
        if (content_ptr != 0) wasmFree(content_ptr, content_len);
        return;
    }

    // Wrap the JS-allocated memory
    const name_slice: []const u8 = if (name_ptr != 0 and name_len > 0)
        @as([*]const u8, @ptrFromInt(name_ptr))[0..name_len]
    else
        "";

    const content_slice: []const u8 = if (content_ptr != 0 and content_len > 0)
        @as([*]const u8, @ptrFromInt(content_ptr))[0..content_len]
    else
        "";

    // Duplicate into our own allocations (so we can properly track ownership)
    const owned_name = global_allocator.dupe(u8, name_slice) catch {
        imports.err("file_dialog: failed to allocate name", .{});
        if (name_ptr != 0) wasmFree(name_ptr, name_len);
        if (content_ptr != 0) wasmFree(content_ptr, content_len);
        return;
    };

    const owned_content = global_allocator.dupe(u8, content_slice) catch {
        imports.err("file_dialog: failed to allocate content", .{});
        global_allocator.free(owned_name);
        if (name_ptr != 0) wasmFree(name_ptr, name_len);
        if (content_ptr != 0) wasmFree(content_ptr, content_len);
        return;
    };

    // Free the JS-allocated memory
    if (name_ptr != 0) wasmFree(name_ptr, name_len);
    if (content_ptr != 0) wasmFree(content_ptr, content_len);

    // Add to pending files
    pending.?.files.append(global_allocator, .{
        .name = owned_name,
        .content = owned_content,
        .size = content_len,
        .allocator = global_allocator,
    }) catch {
        imports.err("file_dialog: failed to append file", .{});
        global_allocator.free(owned_name);
        global_allocator.free(owned_content);
        return;
    };

    pending.?.received_count += 1;

    // Check if we've received all files
    if (pending.?.received_count >= pending.?.expected_count) {
        onFileDialogComplete(request_id);
    }
}

/// Called when all files have been received (internal or from JS)
export fn onFileDialogComplete(request_id: u32) void {
    const kv = pending_requests.fetchRemove(request_id);
    if (kv == null) return;

    var entry = kv.?.value;
    const callback = entry.callback;

    // Convert ArrayList to owned slice
    const files = entry.files.toOwnedSlice(global_allocator) catch {
        imports.err("file_dialog: failed to finalize files", .{});
        for (entry.files.items) |*file| {
            file.deinit();
        }
        entry.files.deinit(global_allocator);
        callback(request_id, null);
        return;
    };

    // Build result
    const result = WebFileDialogResult{
        .files = files,
        .allocator = global_allocator,
    };

    callback(request_id, result);
}

/// Allocate memory from WASM heap (called by JS to store file data)
export fn wasmFileAlloc(size: u32) u32 {
    if (!initialized) return 0;

    const slice = global_allocator.alloc(u8, size) catch {
        imports.err("wasmFileAlloc: failed to allocate {} bytes", .{size});
        return 0;
    };

    return @intFromPtr(slice.ptr);
}

/// Free memory on WASM heap
fn wasmFree(ptr: u32, size: u32) void {
    if (!initialized or ptr == 0 or size == 0) return;

    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    const slice = slice_ptr[0..size];
    global_allocator.free(slice);
}

// ============================================================================
// Convenience Wrappers
// ============================================================================

/// Open a single file with a simple callback
pub fn openSingleFileAsync(
    accept: ?[]const u8,
    callback: FileDialogCallback,
) ?u32 {
    return openFilesAsync(.{
        .accept = accept,
        .multiple = false,
        .directories = false,
    }, callback);
}

/// Open multiple files with a callback
pub fn openMultipleFilesAsync(
    accept: ?[]const u8,
    callback: FileDialogCallback,
) ?u32 {
    return openFilesAsync(.{
        .accept = accept,
        .multiple = true,
        .directories = false,
    }, callback);
}

/// Open directory selection (Chrome/Edge only)
pub fn openDirectoryAsync(
    callback: FileDialogCallback,
) ?u32 {
    return openFilesAsync(.{
        .accept = null,
        .multiple = false,
        .directories = true,
    }, callback);
}

// ============================================================================
// Tests
// ============================================================================

test "OpenDialogOptions defaults" {
    const opts = OpenDialogOptions{};
    try std.testing.expect(opts.accept == null);
    try std.testing.expect(opts.multiple == false);
    try std.testing.expect(opts.directories == false);
}
