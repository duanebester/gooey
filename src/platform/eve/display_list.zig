const std = @import("std");
const chip = @import("chip.zig");
const eve_limits = @import("limits.zig");

const assert = std.debug.assert;

pub const words_max: u32 = eve_limits.EveLimits.bt81x.display_list_words_frame_max;
pub const preamble_words: u32 = 7;
pub const rect_words_max: u32 = 10;
pub const cell_words_max: u32 = 16;
pub const image_words_max: u32 = 17;
pub const image_rounded_words_extra: u32 = 2 * rect_words_max + 10;
pub const strip_words_max: u32 = 8;
pub const handle_count_max: u32 = 14;
pub const image_handle: u32 = 14;

const vertex2ii_extent: i32 = 512;
const vertex_fraction_bits: u32 = 3;

comptime {
    assert(words_max <= chip.display_list_words_max);
    assert(preamble_words + 1 == eve_limits.EveLimits.bt81x.display_list_frame_words);
    assert(handle_count_max <= 16);
    assert(image_handle >= handle_count_max);
    assert(image_handle < 15);
    assert(preamble_words + 1 < words_max);
}

const prim_bitmaps: u32 = 1;
const prim_points: u32 = 2;
const prim_line_strip: u32 = 4;
const prim_rects: u32 = 9;
const format_l8: u32 = 3;
const format_argb4: u32 = 6;
const stencil_always: u32 = 7;
const stencil_equal: u32 = 5;
const stencil_not_equal: u32 = 6;
const stencil_keep: u32 = 1;
const stencil_replace: u32 = 2;

pub const Box = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const Scissor = [4]u32;

pub const Color = struct {
    rgb: u32,
    alpha: u8,
};

pub const ImageDraw = struct {
    source: u32,
    stride: u32,
    texels: [2]u32,
    size: [2]u32,
    at: [2]i32,
    color: Color,
};

pub const PageLayout = struct {
    address: u32,
    cell_size: u32,
};

const DrawState = struct {
    primitive: u32 = 0xFF,
    rgb: u32 = 0xFFFFFF,
    alpha: u8 = 255,
    line_width: u32 = 16,
    point_size: u32 = 16,
    scissor: Scissor = .{ 0, 0, 0, 0 },
    translate: [2]i32 = .{ 0, 0 },
    transform: [2]u32 = .{ 256, 256 },
};

pub const DisplayList = struct {
    words: [words_max]u32 = undefined,
    count: u32 = 0,
    state: DrawState = .{},
    panel: Scissor = .{ 0, 0, 0, 0 },
    clip: Scissor = .{ 0, 0, 0, 0 },
    pages_configured: u16 = 0,

    const Self = @This();

    pub fn begin(self: *Self, panel_width: u32, panel_height: u32, clear: u32) void {
        assert(panel_width > 0);
        assert(panel_height > 0);
        assert(clear <= 0xFFFFFF);
        self.count = 0;
        self.state = .{};
        self.pages_configured = 0;
        self.panel = .{ 0, 0, panel_width, panel_height };
        self.clip = self.panel;
        self.emit((2 << 24) | clear);
        self.emit((38 << 24) | 0b111);
        self.emit((39 << 24) | vertex_fraction_bits);
        self.emit(colorRgb(self.state.rgb));
        self.emit(colorA(self.state.alpha));
        self.state.scissor = self.panel;
        self.emit(scissorXy(0, 0));
        self.emit(scissorSize(panel_width, panel_height));
        assert(self.count == preamble_words);
    }

    pub fn finish(self: *Self) []const u32 {
        assert(self.count < words_max);
        self.words[self.count] = 0;
        self.count += 1;
        assert(self.words[self.count - 1] == 0);
        return self.words[0..self.count];
    }

    pub fn room(self: *const Self, words: u32) bool {
        assert(words > 0);
        assert(self.count < words_max);
        return self.count + words + 1 <= words_max;
    }

    pub fn setClip(self: *Self, clip: Scissor) void {
        assert(clip[2] > 0);
        assert(clip[3] > 0);
        assert(clip[0] + clip[2] <= self.panel[2]);
        assert(clip[1] + clip[3] <= self.panel[3]);
        self.clip = clip;
    }

    pub fn roundRect(self: *Self, box: Box, radius: f32, color: Color) void {
        assert(box.w > 0);
        assert(box.h > 0);
        assert(radius >= 0);
        const corner = @min(radius, @min(box.w, box.h) / 2);
        if (corner < 1) return self.squareRect(box, color);
        const width = roundUnits(corner * 16);
        const inset = @as(f32, @floatFromInt(width)) / 16;
        self.applyScissor(self.clip);
        self.setColor(color);
        self.setLineWidth(width);
        self.beginPrimitive(prim_rects, false);
        self.vertex(box.x + inset, box.y + inset);
        self.vertex(
            @max(box.x + box.w - inset, box.x + inset),
            @max(box.y + box.h - inset, box.y + inset),
        );
    }

    pub fn squareRect(self: *Self, box: Box, color: Color) void {
        assert(box.w > 0);
        assert(box.h > 0);
        const clip = self.clip;
        const left = @max(snap(box.x), @as(i64, clip[0]));
        const top = @max(snap(box.y), @as(i64, clip[1]));
        const right = @min(snap(box.x + box.w), @as(i64, clip[0] + clip[2]));
        const bottom = @min(snap(box.y + box.h), @as(i64, clip[1] + clip[3]));
        if (right <= left or bottom <= top) return;
        self.applyScissor(.{
            @intCast(left),
            @intCast(top),
            @intCast(right - left),
            @intCast(bottom - top),
        });
        self.setColor(color);
        self.setLineWidth(16);
        self.beginPrimitive(prim_rects, false);
        self.vertex(@floatFromInt(left), @floatFromInt(top));
        self.vertex(@floatFromInt(right), @floatFromInt(bottom));
    }

    pub fn stencilMarkBegin(self: *Self) void {
        self.emit(colorMask(false));
        self.emit(stencilFunc(stencil_always, 1));
        self.emit(stencilOp(stencil_replace, stencil_replace));
    }

    pub fn stencilOutsideBegin(self: *Self) void {
        self.emit(colorMask(true));
        self.emit(stencilFunc(stencil_not_equal, 1));
        self.emit(stencilOp(stencil_keep, stencil_keep));
    }

    pub fn stencilTestEnd(self: *Self) void {
        self.emit(stencilFunc(stencil_always, 0));
    }

    pub fn stencilUnmarkBegin(self: *Self) void {
        self.emit(colorMask(false));
        self.emit(stencilOp(stencil_replace, stencil_replace));
    }

    pub fn stencilUnmarkEnd(self: *Self) void {
        self.emit(colorMask(true));
        self.emit(stencilOp(stencil_keep, stencil_keep));
    }

    pub fn cell(
        self: *Self,
        page: u8,
        layout: PageLayout,
        index: u8,
        at: [2]i32,
        color: Color,
    ) void {
        assert(page < handle_count_max);
        assert(index < 128);
        self.applyScissor(self.clip);
        self.configurePage(page, layout);
        self.setTransform(.{ 256, 256 });
        self.setColor(color);
        self.beginPrimitive(prim_bitmaps, false);
        self.vertex2ii(at, page, index);
    }

    pub fn image(self: *Self, draw: *const ImageDraw) void {
        assert(draw.texels[0] > 0);
        assert(draw.texels[1] > 0);
        assert(draw.stride < 4096);
        assert(draw.size[0] > 0);
        assert(draw.size[0] < 2048);
        assert(draw.size[1] > 0);
        assert(draw.size[1] < 2048);
        self.applyScissor(self.clip);
        const handle = image_handle;
        const stride = draw.stride;
        const rows = draw.texels[1];
        const width = draw.size[0];
        const height = draw.size[1];
        const scaled = draw.texels[0] != width or rows != height;
        const filter: u32 = @intFromBool(scaled);
        self.emit((5 << 24) | handle);
        self.emit((1 << 24) | draw.source);
        self.emit((7 << 24) | (format_argb4 << 19) | ((stride & 1023) << 9) | (rows & 511));
        self.emit((40 << 24) | ((stride >> 10) << 2) | (rows >> 9));
        self.emit((8 << 24) | (filter << 20) | ((width & 511) << 9) | (height & 511));
        self.emit((41 << 24) | ((width >> 9) << 2) | (height >> 9));
        self.setTransform(.{ transformOf(draw.texels[0], width), transformOf(rows, height) });
        self.setColor(draw.color);
        self.beginPrimitive(prim_bitmaps, false);
        self.vertex2ii(draw.at, image_handle, 0);
    }

    pub fn imageRounded(self: *Self, box: Box, radius: f32, draw: *const ImageDraw) void {
        assert(radius > 0);
        assert(box.w > 0);
        self.stencilMarkBegin();
        self.roundRect(box, radius, draw.color);
        self.emit(colorMask(true));
        self.emit(stencilFunc(stencil_equal, 1));
        self.emit(stencilOp(stencil_keep, stencil_keep));
        self.image(draw);
        self.stencilTestEnd();
        self.stencilUnmarkBegin();
        self.roundRect(box, radius, draw.color);
        self.stencilUnmarkEnd();
    }

    fn vertex2ii(self: *Self, at: [2]i32, handle: u32, cell_index: u32) void {
        assert(handle < 32);
        assert(cell_index < 128);
        const x = std.math.clamp(at[0], -2048, 2047);
        const y = std.math.clamp(at[1], -2048, 2047);
        const origin = [2]i32{
            @divFloor(x, vertex2ii_extent) * vertex2ii_extent,
            @divFloor(y, vertex2ii_extent) * vertex2ii_extent,
        };
        self.setTranslate(origin);
        const local_x: u32 = @intCast(x - origin[0]);
        const local_y: u32 = @intCast(y - origin[1]);
        assert(local_x < 512);
        assert(local_y < 512);
        self.emit((2 << 30) | (local_x << 21) | (local_y << 12) | (handle << 7) | cell_index);
    }

    pub fn beginStrip(self: *Self, half_width_units: u32, color: Color) void {
        assert(half_width_units > 0);
        assert(half_width_units <= 4095);
        self.applyScissor(self.clip);
        self.setColor(color);
        self.setLineWidth(half_width_units);
        self.beginPrimitive(prim_line_strip, true);
        self.setTranslate(.{ 0, 0 });
    }

    pub fn beginPoints(self: *Self, radius_units: u32, color: Color) void {
        assert(radius_units > 0);
        assert(radius_units <= 0x1FFF);
        self.applyScissor(self.clip);
        self.setColor(color);
        if (self.state.point_size != radius_units) {
            self.emit((13 << 24) | radius_units);
            self.state.point_size = radius_units;
        }
        self.beginPrimitive(prim_points, false);
        self.setTranslate(.{ 0, 0 });
    }

    pub fn vertex(self: *Self, x: f32, y: f32) void {
        self.setTranslate(.{ 0, 0 });
        self.emit(vertex2f(x, y));
    }

    fn configurePage(self: *Self, index: u8, layout: PageLayout) void {
        assert(index < handle_count_max);
        assert(layout.cell_size > 0);
        assert(layout.cell_size < 512);
        const bit = @as(u16, 1) << @intCast(index);
        if (self.pages_configured & bit != 0) return;
        const size = layout.cell_size;
        self.emit((5 << 24) | @as(u32, index));
        self.emit((1 << 24) | layout.address);
        self.emit((7 << 24) | (format_l8 << 19) | (size << 9) | size);
        self.emit(40 << 24);
        self.emit((8 << 24) | (size << 9) | size);
        self.emit(41 << 24);
        self.pages_configured |= bit;
    }

    fn setTransform(self: *Self, transform: [2]u32) void {
        assert(transform[0] > 0);
        assert(transform[1] > 0);
        assert(transform[0] < 0x10000);
        assert(transform[1] < 0x10000);
        if (self.state.transform[0] != transform[0]) {
            self.emit((21 << 24) | transform[0]);
            self.state.transform[0] = transform[0];
        }
        if (self.state.transform[1] != transform[1]) {
            self.emit((25 << 24) | transform[1]);
            self.state.transform[1] = transform[1];
        }
    }

    fn setTranslate(self: *Self, origin: [2]i32) void {
        if (self.state.translate[0] != origin[0]) {
            self.emit((43 << 24) | (@as(u32, @bitCast(origin[0] * 16)) & 0x1FFFF));
            self.state.translate[0] = origin[0];
        }
        if (self.state.translate[1] != origin[1]) {
            self.emit((44 << 24) | (@as(u32, @bitCast(origin[1] * 16)) & 0x1FFFF));
            self.state.translate[1] = origin[1];
        }
    }

    fn setColor(self: *Self, color: Color) void {
        assert(color.rgb <= 0xFFFFFF);
        if (self.state.rgb != color.rgb) {
            self.emit(colorRgb(color.rgb));
            self.state.rgb = color.rgb;
        }
        if (self.state.alpha != color.alpha) {
            self.emit(colorA(color.alpha));
            self.state.alpha = color.alpha;
        }
    }

    fn setLineWidth(self: *Self, width: u32) void {
        assert(width > 0);
        assert(width <= 4095);
        if (self.state.line_width == width) return;
        self.emit((14 << 24) | width);
        self.state.line_width = width;
    }

    fn beginPrimitive(self: *Self, primitive: u32, restart: bool) void {
        assert(primitive <= 9);
        if (self.state.primitive == primitive and !restart) return;
        self.emit((31 << 24) | primitive);
        self.state.primitive = primitive;
    }

    fn applyScissor(self: *Self, scissor: Scissor) void {
        assert(scissor[2] > 0);
        assert(scissor[3] > 0);
        if (std.mem.eql(u32, &scissor, &self.state.scissor)) return;
        if (scissor[0] != self.state.scissor[0] or scissor[1] != self.state.scissor[1]) {
            self.emit(scissorXy(scissor[0], scissor[1]));
        }
        if (scissor[2] != self.state.scissor[2] or scissor[3] != self.state.scissor[3]) {
            self.emit(scissorSize(scissor[2], scissor[3]));
        }
        self.state.scissor = scissor;
    }

    fn emit(self: *Self, word: u32) void {
        assert(self.count + 1 < words_max);
        self.words[self.count] = word;
        self.count += 1;
    }
};

fn colorRgb(rgb: u32) u32 {
    assert(rgb <= 0xFFFFFF);
    return (4 << 24) | rgb;
}

fn transformOf(count: u32, pixels: u32) u32 {
    assert(count > 0);
    assert(pixels > 0);
    const value = (@as(u64, count) * 256 + pixels / 2) / pixels;
    return @intCast(std.math.clamp(value, 1, 0xFFFF));
}

fn colorA(alpha: u8) u32 {
    return (16 << 24) | @as(u32, alpha);
}

pub fn scissorXy(x: u32, y: u32) u32 {
    assert(x < 2048);
    assert(y < 2048);
    return (27 << 24) | (x << 11) | y;
}

pub fn scissorSize(w: u32, h: u32) u32 {
    assert(w <= 2048);
    assert(h <= 2048);
    return (28 << 24) | (w << 12) | h;
}

fn colorMask(on: bool) u32 {
    return (32 << 24) | if (on) @as(u32, 0xF) else 0;
}

fn stencilFunc(function: u32, reference: u32) u32 {
    assert(function <= 7);
    assert(reference <= 255);
    return (10 << 24) | (function << 16) | (reference << 8) | 0xFF;
}

fn stencilOp(fail: u32, pass: u32) u32 {
    assert(fail <= 7);
    assert(pass <= 7);
    return (12 << 24) | (fail << 3) | pass;
}

pub fn vertex2f(x: f32, y: f32) u32 {
    const ux: u32 = @bitCast(eighths(x));
    const uy: u32 = @bitCast(eighths(y));
    return (1 << 30) | ((ux & 0x7FFF) << 15) | (uy & 0x7FFF);
}

fn eighths(value: f32) i32 {
    assert(!std.math.isNan(value));
    return @intFromFloat(std.math.clamp(@round(value * 8), -16384, 16383));
}

fn snap(value: f32) i64 {
    assert(!std.math.isNan(value));
    return @intFromFloat(std.math.clamp(@round(value), -4096, 4096));
}

pub fn roundUnits(value: f32) u32 {
    assert(!std.math.isNan(value));
    return @intFromFloat(std.math.clamp(@round(value), 0, 4095));
}

const testing = std.testing;

const white = Color{ .rgb = 0xFFFFFF, .alpha = 255 };

fn testList(list: *DisplayList) void {
    list.begin(1024, 600, 0);
}

fn containsSequence(words: []const u32, sequence: []const u32) bool {
    if (words.len < sequence.len) return false;
    var start: usize = 0;
    while (start + sequence.len <= words.len) : (start += 1) {
        if (std.mem.eql(u32, words[start..][0..sequence.len], sequence)) return true;
    }
    return false;
}

test "a rounded rect is inset by its radius, which is the line width" {
    var list: DisplayList = .{};
    testList(&list);
    list.roundRect(.{ .x = 10, .y = 20, .w = 100, .h = 40 }, 8, white);
    const words = list.finish();
    try testing.expect(containsSequence(words, &.{
        (14 << 24) | 128,
        (31 << 24) | prim_rects,
        vertex2f(18, 28),
        vertex2f(102, 52),
    }));
}

test "square rects use a 1 px radius scissored to their pixel bounds" {
    var list: DisplayList = .{};
    testList(&list);
    list.squareRect(.{ .x = 40, .y = 0, .w = 1, .h = 100 }, white);
    const words = list.finish();
    try testing.expect(containsSequence(words, &.{ scissorXy(40, 0), scissorSize(1, 100) }));
    try testing.expect(containsSequence(words, &.{ (31 << 24) | prim_rects, vertex2f(40, 0) }));
    for (words) |word| {
        if (word >> 24 == 14) try testing.expect(word & 0xFFF >= 16);
    }
}

test "cells past 511 px shift the origin, and later vertices shift it back" {
    var list: DisplayList = .{};
    testList(&list);
    list.cell(0, .{ .address = 0, .cell_size = 8 }, 1, .{ 600, 40 }, white);
    list.squareRect(.{ .x = 10, .y = 10, .w = 20, .h = 20 }, white);
    const words = list.finish();
    const shifted = (2 << 30) | (88 << 21) | (40 << 12) | 1;
    try testing.expect(containsSequence(words, &.{ (43 << 24) | 8192, shifted }));
    const back = [_]u32{ (43 << 24) | 0, vertex2f(10, 10), vertex2f(30, 30) };
    try testing.expect(containsSequence(words, &back));
}

test "the list fills exactly to its last word and closes with DISPLAY" {
    var list: DisplayList = .{};
    testList(&list);
    const free = words_max - preamble_words - 1;
    try testing.expect(list.room(free));
    try testing.expect(!list.room(free + 1));
    var index: u32 = 0;
    while (index < free) : (index += 1) list.vertex(1, 1);
    try testing.expect(!list.room(1));
    const words = list.finish();
    try testing.expectEqual(@as(usize, words_max), words.len);
    try testing.expectEqual(@as(u32, 0), words[words_max - 1]);
}
