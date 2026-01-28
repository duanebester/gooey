//! WASM Image Loader - Async image decoding via browser APIs
//!
//! Provides async image loading for WASM targets using the browser's
//! createImageBitmap API. JavaScript decodes the image and calls back
//! into WASM with the decoded RGBA pixel data.
//!
//! Flow for loadFromMemoryAsync:
//! 1. Zig calls requestImageDecode() with image bytes
//! 2. JS decodes asynchronously using createImageBitmap + Canvas2D
//! 3. JS allocates WASM memory via wasmAlloc()
//! 4. JS copies pixels and calls onImageDecoded()
//! 5. Zig processes the decoded image
//!
//! Flow for loadFromUrlAsync:
//! 1. Zig calls requestUrlFetch() with URL string
//! 2. JS fetches URL using fetch API
//! 3. JS decodes asynchronously using createImageBitmap + Canvas2D
//! 4. JS allocates WASM memory via wasmAlloc()
//! 5. JS copies pixels and calls onImageDecoded()
//! 6. Zig processes the decoded image

const std = @import("std");
const imports = @import("imports.zig");

/// Result of async image decoding
pub const DecodedImage = struct {
    width: u32,
    height: u32,
    /// RGBA pixel data
    pixels: []u8,
    /// True if we own this memory and should free it
    owned: bool,

    pub fn deinit(self: *DecodedImage, allocator: std.mem.Allocator) void {
        if (self.owned and self.pixels.len > 0) {
            allocator.free(self.pixels);
        }
        self.* = undefined;
    }
};

/// Callback type for async image loading
pub const DecodeCallback = *const fn (request_id: u32, result: ?DecodedImage) void;

/// Pending decode request
const PendingDecode = struct {
    callback: DecodeCallback,
};

/// Global state for pending decode requests
var pending_requests: std.AutoHashMap(u32, PendingDecode) = undefined;
var next_request_id: u32 = 1;
var initialized: bool = false;
var global_allocator: std.mem.Allocator = undefined;

/// Initialize the async image loader
pub fn init(allocator: std.mem.Allocator) void {
    if (initialized) return;
    global_allocator = allocator;
    pending_requests = std.AutoHashMap(u32, PendingDecode).init(allocator);
    initialized = true;
}

/// Deinitialize and free resources
pub fn deinit() void {
    if (!initialized) return;
    pending_requests.deinit();
    initialized = false;
}

/// Request async image decode from encoded bytes (PNG, JPEG, etc.)
/// The callback will be invoked when decoding completes (or fails).
/// Returns the request_id for tracking.
pub fn loadFromMemoryAsync(
    data: []const u8,
    callback: DecodeCallback,
) ?u32 {
    if (!initialized) {
        imports.err("image_loader: not initialized", .{});
        return null;
    }

    const request_id = next_request_id;
    next_request_id +%= 1;

    pending_requests.put(request_id, .{
        .callback = callback,
    }) catch {
        imports.err("image_loader: failed to track request {}", .{request_id});
        return null;
    };

    // Call into JavaScript to start async decode
    imports.requestImageDecode(data.ptr, @intCast(data.len), request_id);

    return request_id;
}

/// Request async image load from URL.
/// The callback will be invoked when loading/decoding completes (or fails).
/// Returns the request_id for tracking.
pub fn loadFromUrlAsync(
    url: []const u8,
    callback: DecodeCallback,
) ?u32 {
    if (!initialized) {
        imports.err("image_loader: not initialized", .{});
        return null;
    }

    const request_id = next_request_id;
    next_request_id +%= 1;

    pending_requests.put(request_id, .{
        .callback = callback,
    }) catch {
        imports.err("image_loader: failed to track request {}", .{request_id});
        return null;
    };

    // Call into JavaScript to start async fetch + decode
    imports.requestUrlFetch(url.ptr, @intCast(url.len), request_id);

    return request_id;
}

/// Cancel a pending decode request
pub fn cancelRequest(request_id: u32) void {
    _ = pending_requests.remove(request_id);
}

/// Check if a request is still pending
pub fn isPending(request_id: u32) bool {
    return pending_requests.contains(request_id);
}

// =============================================================================
// WASM Exports (called from JavaScript)
// =============================================================================

/// Allocate memory from WASM heap (called by JS to store decoded pixels)
export fn wasmAlloc(size: u32) u32 {
    if (!initialized) return 0;

    const slice = global_allocator.alloc(u8, size) catch {
        imports.err("wasmAlloc: failed to allocate {} bytes", .{size});
        return 0;
    };

    return @intFromPtr(slice.ptr);
}

/// Free memory on WASM heap (called by JS if needed)
export fn wasmFree(ptr: u32, size: u32) void {
    if (!initialized or ptr == 0) return;

    const slice_ptr: [*]u8 = @ptrFromInt(ptr);
    const slice = slice_ptr[0..size];
    global_allocator.free(slice);
}

/// Called by JavaScript when image decode completes
/// width/height of 0 indicates decode failure
export fn onImageDecoded(
    request_id: u32,
    width: u32,
    height: u32,
    pixels_ptr: u32,
    pixels_len: u32,
) void {
    const pending = pending_requests.fetchRemove(request_id);
    if (pending == null) {
        // Request was cancelled or unknown
        // Free the pixels if they were allocated
        if (pixels_ptr != 0 and pixels_len > 0) {
            wasmFree(pixels_ptr, pixels_len);
        }
        return;
    }

    const callback = pending.?.value.callback;

    // Check for decode failure
    if (width == 0 or height == 0 or pixels_ptr == 0) {
        callback(request_id, null);
        return;
    }

    // Wrap the JS-allocated memory
    const ptr: [*]u8 = @ptrFromInt(pixels_ptr);
    const decoded = DecodedImage{
        .width = width,
        .height = height,
        .pixels = ptr[0..pixels_len],
        .owned = true, // We own this memory (allocated via wasmAlloc)
    };

    callback(request_id, decoded);
}

// =============================================================================
// Synchronous Fallback (placeholder pattern)
// =============================================================================

/// Create a placeholder image (solid color) for use while async loads
pub fn createPlaceholder(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    r: u8,
    g: u8,
    b: u8,
    a: u8,
) !DecodedImage {
    const pixels = try allocator.alloc(u8, width * height * 4);

    var i: usize = 0;
    while (i < width * height) : (i += 1) {
        const offset = i * 4;
        pixels[offset + 0] = r;
        pixels[offset + 1] = g;
        pixels[offset + 2] = b;
        pixels[offset + 3] = a;
    }

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .owned = true,
    };
}

/// Create a checkerboard pattern (for loading indicators)
pub fn createCheckerboard(
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    cell_size: u32,
) !DecodedImage {
    const pixels = try allocator.alloc(u8, width * height * 4);

    const light = [4]u8{ 200, 200, 200, 255 };
    const dark = [4]u8{ 150, 150, 150, 255 };

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const cell_x = x / cell_size;
            const cell_y = y / cell_size;
            const is_light = (cell_x + cell_y) % 2 == 0;
            const color = if (is_light) light else dark;

            const offset = (y * width + x) * 4;
            @memcpy(pixels[offset..][0..4], &color);
        }
    }

    return DecodedImage{
        .width = width,
        .height = height,
        .pixels = pixels,
        .owned = true,
    };
}
