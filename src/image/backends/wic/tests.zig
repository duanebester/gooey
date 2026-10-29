//! WIC backend tests against the system's real Windows Imaging Component.
//!
//! The inputs are PNGs encoded here with stored (uncompressed) deflate blocks,
//! so every pixel and every header field is known exactly and no asset file is
//! needed. They run on any Windows host and nowhere else.

const std = @import("std");
const testing = std.testing;
const decoder = @import("decoder.zig");
const wic = @import("bindings.zig");

const LoadError = decoder.LoadError;

const COINIT_APARTMENTTHREADED: u32 = 0x2;

const ColorType = enum(u8) {
    gray = 0,
    rgb = 2,
    rgba = 6,

    fn channelCount(self: ColorType) u32 {
        return switch (self) {
            .gray => 1,
            .rgb => 3,
            .rgba => 4,
        };
    }
};

const PngOptions = struct {
    width: u32,
    height: u32,
    color_type: ColorType,
};

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };
const stored_block_bytes_max: usize = 65_535;

/// A bounded byte writer over a buffer sized exactly in advance.
const Writer = struct {
    buffer: []u8,
    index: usize = 0,

    fn bytes(self: *Writer, data: []const u8) void {
        std.debug.assert(data.len <= self.buffer.len - self.index);
        @memcpy(self.buffer[self.index..][0..data.len], data);
        self.index += data.len;
    }

    fn int(self: *Writer, comptime T: type, value: T, endian: std.builtin.Endian) void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, endian);
        self.bytes(&encoded);
    }

    /// Writes one chunk: length, type, data, and the CRC of type and data.
    fn chunk(self: *Writer, chunk_type: *const [4]u8, data: []const u8) void {
        std.debug.assert(data.len <= std.math.maxInt(u32));
        self.int(u32, @intCast(data.len), .big);
        const crc_start = self.index;
        self.bytes(chunk_type);
        self.bytes(data);
        self.int(u32, std.hash.Crc32.hash(self.buffer[crc_start..self.index]), .big);
    }
};

/// Encodes 8-bit `pixels` (rows of `width * channels` bytes, unfiltered) as a
/// PNG with filter type 0 on every row and one IDAT of stored deflate blocks.
fn encodePng(options: PngOptions, pixels: []const u8) ![]u8 {
    const row_bytes = @as(usize, options.width) * options.color_type.channelCount();
    std.debug.assert(pixels.len == row_bytes * options.height);

    const raw_len = (row_bytes + 1) * options.height;
    const raw = try testing.allocator.alloc(u8, raw_len);
    defer testing.allocator.free(raw);
    for (0..options.height) |row| {
        raw[row * (row_bytes + 1)] = 0; // Filter type None.
        const source = pixels[row * row_bytes ..][0..row_bytes];
        @memcpy(raw[row * (row_bytes + 1) + 1 ..][0..row_bytes], source);
    }

    std.debug.assert(raw_len > 0);
    const block_count = @divFloor(raw_len + stored_block_bytes_max - 1, stored_block_bytes_max);
    const zlib_len = 2 + raw_len + 5 * block_count + 4;
    const total_len = png_signature.len + (12 + 13) + (12 + zlib_len) + 12;
    const png = try testing.allocator.alloc(u8, total_len);
    errdefer testing.allocator.free(png);

    var writer: Writer = .{ .buffer = png };
    writer.bytes(&png_signature);

    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], options.width, .big);
    std.mem.writeInt(u32, header[4..8], options.height, .big);
    header[8..13].* = .{ 8, @backingInt(options.color_type), 0, 0, 0 };
    writer.chunk("IHDR", &header);

    const zlib = try testing.allocator.alloc(u8, zlib_len);
    defer testing.allocator.free(zlib);
    writeZlibStored(zlib, raw, block_count);
    writer.chunk("IDAT", zlib);
    writer.chunk("IEND", &.{});

    std.debug.assert(writer.index == total_len);
    return png;
}

fn writeZlibStored(target: []u8, raw: []const u8, block_count: usize) void {
    var writer: Writer = .{ .buffer = target };
    writer.bytes(&.{ 0x78, 0x01 }); // Deflate, 32 KiB window, no dictionary.
    var offset: usize = 0;
    for (0..block_count) |block| {
        const len = @min(stored_block_bytes_max, raw.len - offset);
        const is_final: u8 = @intFromBool(block + 1 == block_count);
        writer.bytes(&.{is_final}); // BTYPE 00: stored.
        writer.int(u16, @intCast(len), .little);
        writer.int(u16, ~@as(u16, @intCast(len)), .little);
        writer.bytes(raw[offset..][0..len]);
        offset += len;
    }
    std.debug.assert(offset == raw.len);
    writer.int(u32, std.hash.Adler32.hash(raw), .big);
    std.debug.assert(writer.index == target.len);
}

fn decodePng(options: PngOptions, pixels: []const u8) !decoder.DecodedImage {
    const png = try encodePng(options, pixels);
    defer testing.allocator.free(png);
    return decoder.loadFromMemory(testing.allocator, png);
}

/// A uniform RGBA frame for the size tests.
fn decodeUniform(allocator: std.mem.Allocator, width: u32, height: u32) !decoder.DecodedImage {
    const options: PngOptions = .{ .width = width, .height = height, .color_type = .rgba };
    const pixels = try testing.allocator.alloc(u8, @as(usize, width) * height * 4);
    defer testing.allocator.free(pixels);
    @memset(pixels, 0x7F);

    const png = try encodePng(options, pixels);
    defer testing.allocator.free(png);
    return decoder.loadFromMemory(allocator, png);
}

test "RGBA PNG decodes to straight-alpha RGBA" {
    // Goal: channel order and alpha mode. Methodology: a 2x2 frame with a
    // partially transparent pixel and a fully transparent pixel that still
    // carries color; premultiplied output would scale or zero their channels.
    const pixels = [_]u8{
        255, 0,  0,  255, 0,   255, 0,  255,
        10,  20, 30, 128, 200, 100, 50, 0,
    };
    var image = try decodePng(.{ .width = 2, .height = 2, .color_type = .rgba }, &pixels);
    defer image.deinit();

    try testing.expectEqual(@as(u32, 2), image.width);
    try testing.expectEqual(@as(u32, 2), image.height);
    try testing.expectEqualSlices(u8, &pixels, image.pixels);

    const image_data = image.toImageData();
    try testing.expectEqual(.rgba, image_data.format);
    try testing.expectEqual(image.pixels.ptr, image_data.pixels.ptr);
}

test "gray and RGB PNGs expand to opaque RGBA" {
    // Goal: format conversion for sources without alpha. Methodology: one row
    // of three pixels in each color type; every output pixel must be opaque.
    const gray = [_]u8{ 0, 128, 255 };
    var gray_image = try decodePng(.{ .width = 3, .height = 1, .color_type = .gray }, &gray);
    defer gray_image.deinit();
    const gray_expected = [_]u8{ 0, 0, 0, 255, 128, 128, 128, 255, 255, 255, 255, 255 };
    try testing.expectEqualSlices(u8, &gray_expected, gray_image.pixels);

    const rgb = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var rgb_image = try decodePng(.{ .width = 3, .height = 1, .color_type = .rgb }, &rgb);
    defer rgb_image.deinit();
    const rgb_expected = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255, 7, 8, 9, 255 };
    try testing.expectEqualSlices(u8, &rgb_expected, rgb_image.pixels);
}

test "empty and unrecognized data are invalid formats" {
    // Goal: input WIC cannot identify maps to `InvalidFormat`, not a decode
    // failure. Methodology: no bytes, and bytes no codec claims.
    const empty = decoder.loadFromMemory(testing.allocator, &.{});
    try testing.expectError(LoadError.InvalidFormat, empty);
    const garbage = "this is not an image, only text that no codec recognizes";
    const unrecognized = decoder.loadFromMemory(testing.allocator, garbage);
    try testing.expectError(LoadError.InvalidFormat, unrecognized);
}

test "truncated PNG keeps its decoded rows and zeroes the rest" {
    // Goal: WIC accepts a PNG cut inside its pixel data (and even corrupt
    // deflate data), so the rows it never decoded must be deterministic.
    // Methodology: cut a 16x16 PNG midway through its IDAT; the first row must survive and the last must be
    // transparent black, not stale allocator bytes.
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (&pixels, 0..) |*byte, index| byte.* = @truncate(index | 1);
    const png = try encodePng(.{ .width = 16, .height = 16, .color_type = .rgba }, &pixels);
    defer testing.allocator.free(png);

    var image = try decoder.loadFromMemory(testing.allocator, png[0 .. png.len / 2]);
    defer image.deinit();
    const row_bytes = 16 * 4;
    try testing.expectEqualSlices(u8, pixels[0..row_bytes], image.pixels[0..row_bytes]);
    const last_row = image.pixels[image.pixels.len - row_bytes ..];
    try testing.expectEqualSlices(u8, &@as([row_bytes]u8, @splat(0)), last_row);
}

test "PNG with an invalid header is an invalid format" {
    // Goal: WIC's PNG codec probes the header before claiming the data, so a
    // valid signature over an invalid header is `InvalidFormat`, like data
    // no codec recognizes. Methodology: set IHDR's bit depth to 7, which no
    // PNG color type allows, and recompute the chunk CRC so the bit depth is
    // the only defect.
    var pixels: [4 * 4 * 4]u8 = undefined;
    @memset(&pixels, 0x42);
    const png = try encodePng(.{ .width = 4, .height = 4, .color_type = .rgba }, &pixels);
    defer testing.allocator.free(png);

    // IHDR's type starts after the signature and its length; the CRC follows
    // the type and 13 data bytes, and bit depth is data byte 8.
    const type_index = png_signature.len + 4;
    const crc_index = type_index + 4 + 13;
    png[type_index + 4 + 8] = 7;
    const crc = std.hash.Crc32.hash(png[type_index..crc_index]);
    std.mem.writeInt(u32, png[crc_index..][0..4], crc, .big);

    const result = decoder.loadFromMemory(testing.allocator, png);
    try testing.expectError(LoadError.InvalidFormat, result);
}

test "frame side limit: the maximum decodes, one past fails before allocating" {
    // Goal: the `image_side_max` boundary in each dimension. Methodology: the
    // maximum width decodes; one past it in either dimension must fail with
    // `UnsupportedSource` even under an allocator that fails every request,
    // which proves the header is rejected before the pixel buffer exists.
    const side_max = decoder.image_side_max;
    var widest = try decodeUniform(testing.allocator, side_max, 1);
    defer widest.deinit();
    try testing.expectEqual(side_max, widest.width);
    try testing.expectEqual(@as(usize, side_max) * 4, widest.pixels.len);
    try testing.expectEqual(@as(u8, 0x7F), widest.pixels[widest.pixels.len - 1]);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const allocator = failing.allocator();
    try testing.expectError(LoadError.UnsupportedSource, decodeUniform(allocator, side_max + 1, 1));
    try testing.expectError(LoadError.UnsupportedSource, decodeUniform(allocator, 1, side_max + 1));
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}

test "allocation failure reports OutOfMemory" {
    // Goal: the pixel buffer's error path. Methodology: a valid image under an
    // allocator that fails its first request.
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(LoadError.OutOfMemory, decodeUniform(failing.allocator(), 4, 4));
}

test "decoding borrows a thread's existing COM apartment" {
    // Goal: both entry outcomes of `comEnter` besides a fresh MTA. Methodology:
    // initialize the test thread as an STA (decode sees RPC_E_CHANGED_MODE)
    // and then as an MTA (decode sees S_FALSE); both decode, and each test
    // entry is balanced so the thread ends as it started.
    const pixels = [_]u8{ 9, 8, 7, 6 };
    const options: PngOptions = .{ .width = 1, .height = 1, .color_type = .rgba };
    const models = [_]u32{ COINIT_APARTMENTTHREADED, wic.COINIT_MULTITHREADED };
    for (models) |model| {
        const result = wic.CoInitializeEx(null, model);
        try testing.expect(wic.succeeded(result));
        defer wic.CoUninitialize();

        var image = try decodePng(options, &pixels);
        defer image.deinit();
        try testing.expectEqualSlices(u8, &pixels, image.pixels);
    }
}
