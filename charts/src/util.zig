const std = @import("std");
const constants = @import("constants.zig");

const MAX_TICKS = constants.MAX_TICKS;
const MAX_LABEL_LENGTH = constants.MAX_LABEL_LENGTH;

pub fn niceNumber(value: f32, round: bool) f32 {
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));

    if (value == 0) return 0;

    const sign: f32 = if (value < 0) -1.0 else 1.0;
    const abs_value = @abs(value);

    const exp = @floor(std.math.log10(abs_value));
    const fraction = abs_value / std.math.pow(f32, 10.0, exp);

    const nice_fraction = if (round) blk: {
        break :blk if (fraction < 1.5)
            @as(f32, 1.0)
        else if (fraction < 3.0)
            @as(f32, 2.0)
        else if (fraction < 7.0)
            @as(f32, 5.0)
        else
            @as(f32, 10.0);
    } else blk: {
        break :blk if (fraction <= 1.0)
            @as(f32, 1.0)
        else if (fraction <= 2.0)
            @as(f32, 2.0)
        else if (fraction <= 5.0)
            @as(f32, 5.0)
        else
            @as(f32, 10.0);
    };

    return sign * nice_fraction * std.math.pow(f32, 10.0, exp);
}

pub const NiceRangeResult = struct {
    min: f32,
    max: f32,
    step: f32,
    tick_count: u32,
};

pub fn niceRange(min: f32, max: f32, target_ticks: u32) NiceRangeResult {
    std.debug.assert(!std.math.isNan(min) and !std.math.isNan(max));
    std.debug.assert(target_ticks > 0 and target_ticks <= MAX_TICKS);

    if (min == max) {
        if (min == 0) {
            return .{ .min = 0, .max = 1, .step = 0.2, .tick_count = 6 };
        }
        const delta = @abs(min) * 0.1;
        return niceRange(min - delta, max + delta, target_ticks);
    }

    const actual_min = @min(min, max);
    const actual_max = @max(min, max);

    const range = actual_max - actual_min;
    const rough_step = range / @as(f32, @floatFromInt(target_ticks));
    const nice_step = niceNumber(rough_step, true);

    const nice_min = @floor(actual_min / nice_step) * nice_step;
    const nice_max = @ceil(actual_max / nice_step) * nice_step;

    const tick_count: u32 = @intFromFloat(@ceil((nice_max - nice_min) / nice_step) + 1);
    const clamped_count = @min(tick_count, MAX_TICKS);

    return .{
        .min = nice_min,
        .max = nice_max,
        .step = nice_step,
        .tick_count = clamped_count,
    };
}

pub fn formatNumber(value: f32, buffer: *[MAX_LABEL_LENGTH]u8) []const u8 {
    std.debug.assert(!std.math.isNan(value));

    if (std.math.isInf(value)) {
        const inf_str = if (value > 0) "∞" else "-∞";
        @memcpy(buffer[0..inf_str.len], inf_str);
        return buffer[0..inf_str.len];
    }

    const abs_value = @abs(value);
    const is_whole = abs_value == @floor(abs_value) and abs_value < 1e9;

    if (is_whole) {
        return formatInteger(@as(i64, @intFromFloat(value)), buffer);
    }

    const precision: usize = if (abs_value >= 100)
        0
    else if (abs_value >= 10)
        1
    else if (abs_value >= 1)
        2
    else
        3;

    return formatFloat(value, precision, buffer);
}

fn formatInteger(value: i64, buffer: *[MAX_LABEL_LENGTH]u8) []const u8 {
    var temp: [24]u8 = undefined;
    var i: usize = 0;

    var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);

    if (v == 0) {
        temp[i] = '0';
        i += 1;
    } else {
        while (v > 0) : (i += 1) {
            temp[i] = @intCast((v % 10) + '0');
            v /= 10;
        }
    }

    if (value < 0) {
        temp[i] = '-';
        i += 1;
    }

    for (0..i) |j| {
        buffer[j] = temp[i - 1 - j];
    }

    return buffer[0..i];
}

fn formatFloat(value: f32, precision: usize, buffer: *[MAX_LABEL_LENGTH]u8) []const u8 {
    const abs_value = @abs(value);

    const int_part: i64 = @intFromFloat(abs_value);
    var int_buf: [MAX_LABEL_LENGTH]u8 = undefined;
    const int_str = formatInteger(int_part, &int_buf);

    var pos: usize = 0;

    if (value < 0) {
        buffer[pos] = '-';
        pos += 1;
    }

    @memcpy(buffer[pos .. pos + int_str.len], int_str);
    pos += int_str.len;

    if (precision > 0) {
        buffer[pos] = '.';
        pos += 1;

        const frac = abs_value - @as(f32, @floatFromInt(int_part));
        var frac_scaled = frac;

        for (0..precision) |_| {
            frac_scaled *= 10.0;
            const digit: u8 = @intFromFloat(@mod(frac_scaled, 10.0));
            buffer[pos] = digit + '0';
            pos += 1;
        }
    }

    return buffer[0..pos];
}

pub fn formatCompact(value: f32, buffer: *[MAX_LABEL_LENGTH]u8) []const u8 {
    std.debug.assert(!std.math.isNan(value));
    std.debug.assert(!std.math.isInf(value));

    const abs_value = @abs(value);

    if (abs_value >= 1e12) {
        const scaled = value / 1e12;
        const len = formatFloat(scaled, 1, buffer).len;
        buffer[len] = 'T';
        return buffer[0 .. len + 1];
    } else if (abs_value >= 1e9) {
        const scaled = value / 1e9;
        const len = formatFloat(scaled, 1, buffer).len;
        buffer[len] = 'B';
        return buffer[0 .. len + 1];
    } else if (abs_value >= 1e6) {
        const scaled = value / 1e6;
        const len = formatFloat(scaled, 1, buffer).len;
        buffer[len] = 'M';
        return buffer[0 .. len + 1];
    } else if (abs_value >= 1e3) {
        const scaled = value / 1e3;
        const len = formatFloat(scaled, 1, buffer).len;
        buffer[len] = 'K';
        return buffer[0 .. len + 1];
    }

    return formatNumber(value, buffer);
}

pub fn clamp(value: f32, min_val: f32, max_val: f32) f32 {
    std.debug.assert(min_val <= max_val);
    return @max(min_val, @min(max_val, value));
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    std.debug.assert(t >= 0 and t <= 1);
    return a + (b - a) * t;
}

pub fn invLerp(a: f32, b: f32, value: f32) f32 {
    const range = b - a;
    std.debug.assert(range != 0);
    return (value - a) / range;
}

pub const DecimationPoint = struct {
    x: f32,
    y: f32,
};

pub fn triangleArea(p1: DecimationPoint, p2: DecimationPoint, p3: DecimationPoint) f32 {
    return @abs((p1.x - p3.x) * (p2.y - p1.y) - (p1.x - p2.x) * (p3.y - p1.y));
}

pub fn decimateLTTB(
    data: []const DecimationPoint,
    data_len: u32,
    output: []DecimationPoint,
    target_count: u32,
) u32 {
    std.debug.assert(data_len >= 2);
    std.debug.assert(target_count >= 2);
    std.debug.assert(output.len >= target_count);

    if (data_len <= target_count) {
        for (0..data_len) |i| {
            output[i] = data[i];
        }
        return data_len;
    }

    var out_idx: u32 = 0;

    output[out_idx] = data[0];
    out_idx += 1;

    const bucket_size: f32 = @as(f32, @floatFromInt(data_len - 2)) /
        @as(f32, @floatFromInt(target_count - 2));

    var prev_selected: DecimationPoint = data[0];

    var bucket_idx: u32 = 0;
    while (bucket_idx < target_count - 2) : (bucket_idx += 1) {
        const bucket_start: u32 = @intFromFloat(@as(f32, @floatFromInt(bucket_idx)) * bucket_size + 1);
        const bucket_end: u32 = @min(
            @as(u32, @intFromFloat(@as(f32, @floatFromInt(bucket_idx + 1)) * bucket_size + 1)),
            data_len - 1,
        );

        const next_bucket_start: u32 = bucket_end;
        const next_bucket_end: u32 = @min(
            @as(u32, @intFromFloat(@as(f32, @floatFromInt(bucket_idx + 2)) * bucket_size + 1)),
            data_len,
        );

        var avg_x: f32 = 0;
        var avg_y: f32 = 0;
        var avg_count: u32 = 0;

        var j: u32 = next_bucket_start;
        while (j < next_bucket_end) : (j += 1) {
            avg_x += data[j].x;
            avg_y += data[j].y;
            avg_count += 1;
        }

        if (avg_count > 0) {
            avg_x /= @floatFromInt(avg_count);
            avg_y /= @floatFromInt(avg_count);
        }

        const avg_point = DecimationPoint{ .x = avg_x, .y = avg_y };

        var max_area: f32 = 0;
        var selected_idx: u32 = bucket_start;

        var i: u32 = bucket_start;
        while (i < bucket_end) : (i += 1) {
            const area = triangleArea(prev_selected, data[i], avg_point);
            if (area > max_area) {
                max_area = area;
                selected_idx = i;
            }
        }

        output[out_idx] = data[selected_idx];
        prev_selected = data[selected_idx];
        out_idx += 1;
    }

    output[out_idx] = data[data_len - 1];
    out_idx += 1;

    return out_idx;
}

test "niceNumber rounds to nice values" {
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), niceNumber(1.2, true), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), niceNumber(1.8, true), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), niceNumber(4.5, true), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), niceNumber(8.0, true), 0.001);

    try std.testing.expectApproxEqAbs(@as(f32, 2.0), niceNumber(1.2, false), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 5.0), niceNumber(3.0, false), 0.001);
}

test "niceNumber handles different magnitudes" {
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), niceNumber(123.0, true), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), niceNumber(0.45, true), 0.001);
}

test "niceRange calculates sensible ranges" {
    const result = niceRange(0, 155, 5);
    try std.testing.expect(result.min <= 0);
    try std.testing.expect(result.max >= 155);
    try std.testing.expect(result.step > 0);
    try std.testing.expect(result.tick_count <= MAX_TICKS);
}

test "niceRange handles equal min/max" {
    const result = niceRange(50, 50, 5);
    try std.testing.expect(result.min < 50);
    try std.testing.expect(result.max > 50);
}

test "formatNumber formats integers" {
    var buf: [MAX_LABEL_LENGTH]u8 = undefined;
    try std.testing.expectEqualStrings("42", formatNumber(42.0, &buf));
    try std.testing.expectEqualStrings("0", formatNumber(0.0, &buf));
    try std.testing.expectEqualStrings("-123", formatNumber(-123.0, &buf));
}

test "formatNumber formats decimals" {
    var buf: [MAX_LABEL_LENGTH]u8 = undefined;
    const result = formatNumber(3.14, &buf);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(result[0] == '3');
}

test "formatCompact handles large numbers" {
    var buf: [MAX_LABEL_LENGTH]u8 = undefined;

    const k_result = formatCompact(1500, &buf);
    try std.testing.expect(k_result.len > 0);
    try std.testing.expect(k_result[k_result.len - 1] == 'K');

    const m_result = formatCompact(2500000, &buf);
    try std.testing.expect(m_result[m_result.len - 1] == 'M');
}

test "clamp works correctly" {
    try std.testing.expectEqual(@as(f32, 5.0), clamp(3.0, 5.0, 10.0));
    try std.testing.expectEqual(@as(f32, 7.0), clamp(7.0, 5.0, 10.0));
    try std.testing.expectEqual(@as(f32, 10.0), clamp(15.0, 5.0, 10.0));
}

test "lerp interpolates correctly" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), lerp(0.0, 100.0, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50.0), lerp(0.0, 100.0, 0.5), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100.0), lerp(0.0, 100.0, 1.0), 0.001);
}

test "invLerp calculates t correctly" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), invLerp(0.0, 100.0, 0.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), invLerp(0.0, 100.0, 50.0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), invLerp(0.0, 100.0, 100.0), 0.001);
}

test "triangleArea calculates correctly" {
    const p1 = DecimationPoint{ .x = 0, .y = 0 };
    const p2 = DecimationPoint{ .x = 2, .y = 0 };
    const p3 = DecimationPoint{ .x = 0, .y = 2 };

    try std.testing.expectApproxEqAbs(@as(f32, 4.0), triangleArea(p1, p2, p3), 0.001);
}

test "decimateLTTB preserves first and last points" {
    const data = [_]DecimationPoint{
        .{ .x = 0, .y = 10 },
        .{ .x = 1, .y = 20 },
        .{ .x = 2, .y = 15 },
        .{ .x = 3, .y = 25 },
        .{ .x = 4, .y = 30 },
    };

    var output: [3]DecimationPoint = undefined;
    const count = decimateLTTB(&data, 5, &output, 3);

    try std.testing.expectEqual(@as(u32, 3), count);
    try std.testing.expectApproxEqAbs(@as(f32, 0), output[0].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 10), output[0].y, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 4), output[count - 1].x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 30), output[count - 1].y, 0.001);
}

test "decimateLTTB copies when below threshold" {
    const data = [_]DecimationPoint{
        .{ .x = 0, .y = 10 },
        .{ .x = 1, .y = 20 },
        .{ .x = 2, .y = 15 },
    };

    var output: [5]DecimationPoint = undefined;
    const count = decimateLTTB(&data, 3, &output, 5);

    try std.testing.expectEqual(@as(u32, 3), count);
}
