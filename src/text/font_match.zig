//! Face selection within one font family, by the CSS font matching algorithm
//! (CSS Fonts Level 4, §5.2): width narrows the candidates first, then style,
//! then weight.
//!
//! FreeType (through Fontconfig) and CoreText list a family's faces and pick
//! one with `select`, so the same request picks the same face class on Linux,
//! macOS, and in the browser, which applies this rule itself. Nearest-value
//! matching is wrong here: CoreText places Medium (0.23) nearer Bold (0.4)
//! than Regular (0.0), so a family without Medium would render medium as bold.
//!
//! Pure functions over a caller-provided slice: no allocation, no platform
//! state, bounded by the slice length.

const std = @import("std");
const types = @import("types.zig");

const FontVariant = types.FontVariant;

pub const Slant = enum(u8) { upright, italic, oblique };

/// One face of the family being matched.
pub const Candidate = struct {
    /// CSS `font-weight`, 1...1000.
    weight: u16,
    slant: Slant,
    /// CSS `font-stretch` percentage, 50...200; 100 is normal width.
    stretch: u16,
};

/// Faces considered per family. Real families have at most a few dozen; the
/// backends consider the first `candidate_count_max` and log when a family has
/// more, rather than reserving storage for an unbounded list.
pub const candidate_count_max: u32 = 128;

/// Index into `candidates` of the face CSS matching selects for `variant` at
/// `stretch_desired`, or null when `candidates` is empty. Backends pass the
/// width of the face the family name resolved to, so naming a condensed
/// family keeps it condensed and a regular family never picks its condensed
/// bold.
pub fn select(candidates: []const Candidate, variant: FontVariant, stretch_desired: u16) ?u32 {
    std.debug.assert(candidates.len <= candidate_count_max);
    std.debug.assert(stretch_desired >= stretch_min);
    std.debug.assert(stretch_desired <= stretch_max);
    if (candidates.len == 0) return null;

    const stretch = selectStretch(candidates, stretch_desired);
    const slant = selectSlant(candidates, stretch, variant.isItalic());
    const desired = variant.weight().cssWeight();

    var best: ?u32 = null;
    var best_rank: u32 = std.math.maxInt(u32);
    for (candidates, 0..) |candidate, index| {
        std.debug.assert(candidate.weight >= 1);
        std.debug.assert(candidate.weight <= 1000);
        if (candidate.stretch != stretch) continue;
        if (candidate.slant != slant) continue;
        const rank = weightRank(desired, candidate.weight);
        // Strictly better only, so equal weights keep the first listed face.
        if (rank < best_rank) {
            best_rank = rank;
            best = @intCast(index);
        }
    }

    std.debug.assert(best != null);
    std.debug.assert(candidates[best.?].slant == slant);
    return best;
}

pub const stretch_min: u16 = 50;
pub const stretch_max: u16 = 200;
pub const stretch_normal: u16 = 100;

/// The weight class a CSS weight belongs to: the nearest hundred. A chosen
/// face whose class differs from the requested weight gets a warning.
pub fn weightClass(weight: u16) u16 {
    std.debug.assert(weight >= 1);
    std.debug.assert(weight <= 1000);
    const result: u16 = @intCast(@divFloor(@as(u32, weight) + 50, 100) * 100);
    std.debug.assert(result <= 1000);
    return result;
}

/// Whether `slant` satisfies the style the variant asked for: italic and
/// oblique both satisfy an italic request.
pub fn slantMatches(slant: Slant, italic_requested: bool) bool {
    return (slant != .upright) == italic_requested;
}

/// CSS `font-stretch` fallback: the listed width with the lowest rank.
fn selectStretch(candidates: []const Candidate, desired: u16) u16 {
    std.debug.assert(candidates.len > 0);
    var best: u16 = candidates[0].stretch;
    var best_rank: u32 = stretchRank(desired, best);
    for (candidates[1..]) |candidate| {
        const rank = stretchRank(desired, candidate.stretch);
        if (rank < best_rank) {
            best_rank = rank;
            best = candidate.stretch;
        }
    }
    std.debug.assert(best >= stretch_min);
    return best;
}

/// Desired normal or narrower: narrower widths descending, then wider
/// ascending. Desired wider than normal: wider ascending, then narrower.
fn stretchRank(desired: u16, stretch: u16) u32 {
    std.debug.assert(stretch >= stretch_min);
    std.debug.assert(stretch <= stretch_max);
    const tier_span: u32 = 1_000;
    const distance: u32 = @abs(@as(i32, stretch) - @as(i32, desired));
    const tier: u32 = if (desired <= stretch_normal)
        @intFromBool(stretch > desired)
    else
        @intFromBool(stretch < desired);
    return tier * tier_span + distance;
}

/// CSS `font-style` fallback among faces of the chosen width: italic
/// requests try italic, oblique, upright; upright requests try upright,
/// oblique, italic.
fn selectSlant(candidates: []const Candidate, stretch: u16, italic_requested: bool) Slant {
    std.debug.assert(candidates.len > 0);
    const order: [3]Slant = if (italic_requested)
        .{ .italic, .oblique, .upright }
    else
        .{ .upright, .oblique, .italic };
    for (order) |slant| {
        for (candidates) |candidate| {
            if (candidate.stretch != stretch) continue;
            if (candidate.slant == slant) return slant;
        }
    }
    unreachable; // `stretch` is listed, and every face has one of three slants.
}

/// Lower ranks are preferred. The tier encodes the CSS search direction and
/// the distance orders faces within a tier:
/// - desired below 400: lighter faces descending, then heavier ascending;
/// - desired 400...500: weights up to 500 ascending, then lighter descending,
///   then heavier than 500 ascending;
/// - desired above 500: heavier faces ascending, then lighter descending.
fn weightRank(desired: u16, weight: u16) u32 {
    const tier_span: u32 = 1_000;
    const distance: u32 = @abs(@as(i32, weight) - @as(i32, desired));
    std.debug.assert(distance < tier_span);

    const tier: u32 = if (desired < 400) blk: {
        break :blk if (weight <= desired) 0 else 1;
    } else if (desired <= 500) blk: {
        if (weight >= desired) {
            break :blk if (weight <= 500) 0 else 2;
        }
        break :blk 1;
    } else blk: {
        break :blk if (weight >= desired) 0 else 1;
    };
    return tier * tier_span + distance;
}

test "select follows the CSS weight and style rules, not the nearest weight" {
    // Goal: the cases where nearest-weight matching and CSS matching disagree.
    // Methodology: small families as candidate lists; the expected index comes
    // from the CSS Fonts Level 4 rule written out by hand for each request.
    const testing = std.testing;
    const regular_bold = [_]Candidate{
        .{ .weight = 400, .slant = .upright, .stretch = 100 },
        .{ .weight = 700, .slant = .upright, .stretch = 100 },
    };
    // 400...500 tries 500, then lighter: Regular, though Bold is nearer in CoreText.
    try testing.expectEqual(@as(?u32, 0), select(&regular_bold, .medium, 100));
    // Above 500 tries heavier first: Bold, though 600 is equally near both.
    try testing.expectEqual(@as(?u32, 1), select(&regular_bold, .semibold, 100));
    // Below 400 tries lighter first; with none, the lightest heavier face.
    try testing.expectEqual(@as(?u32, 0), select(&regular_bold, .light, 100));

    const light_regular_medium_bold = [_]Candidate{
        .{ .weight = 300, .slant = .upright, .stretch = 100 },
        .{ .weight = 700, .slant = .upright, .stretch = 100 },
        .{ .weight = 500, .slant = .upright, .stretch = 100 },
        .{ .weight = 400, .slant = .upright, .stretch = 100 },
    };
    try testing.expectEqual(@as(?u32, 3), select(&light_regular_medium_bold, .regular, 100));
    try testing.expectEqual(@as(?u32, 2), select(&light_regular_medium_bold, .medium, 100));
    try testing.expectEqual(@as(?u32, 0), select(&light_regular_medium_bold, .thin, 100));

    // No 700: bold falls back to the heaviest lighter face, not to 400.
    const regular_semibold = [_]Candidate{
        .{ .weight = 400, .slant = .upright, .stretch = 100 },
        .{ .weight = 600, .slant = .upright, .stretch = 100 },
    };
    try testing.expectEqual(@as(?u32, 1), select(&regular_semibold, .bold, 100));
    // Medium with no 500: lighter (400) wins over the heavier 600.
    try testing.expectEqual(@as(?u32, 0), select(&regular_semibold, .medium, 100));

    // Style narrows first: an italic request uses the oblique face even when
    // an upright face has the requested weight.
    const upright_and_oblique = [_]Candidate{
        .{ .weight = 400, .slant = .upright, .stretch = 100 },
        .{ .weight = 700, .slant = .upright, .stretch = 100 },
        .{ .weight = 400, .slant = .oblique, .stretch = 100 },
    };
    try testing.expectEqual(@as(?u32, 2), select(&upright_and_oblique, .italic, 100));
    try testing.expectEqual(@as(?u32, 2), select(&upright_and_oblique, .bold_italic, 100));
    try testing.expectEqual(@as(?u32, 1), select(&upright_and_oblique, .bold, 100));

    // No upright face at all: upright requests fall back to italic.
    const italic_only = [_]Candidate{.{ .weight = 400, .slant = .italic, .stretch = 100 }};
    try testing.expectEqual(@as(?u32, 0), select(&italic_only, .bold, 100));

    try testing.expectEqual(@as(?u32, null), select(&.{}, .regular, 100));

    // Width narrows before weight: a family that lists its condensed bold
    // first (DejaVu Sans with the Condensed faces installed, Helvetica Neue)
    // keeps normal width for bold, and a condensed request stays condensed.
    const with_condensed = [_]Candidate{
        .{ .weight = 700, .slant = .upright, .stretch = 75 },
        .{ .weight = 400, .slant = .upright, .stretch = 100 },
        .{ .weight = 700, .slant = .upright, .stretch = 100 },
        .{ .weight = 400, .slant = .upright, .stretch = 75 },
    };
    try testing.expectEqual(@as(?u32, 2), select(&with_condensed, .bold, 100));
    try testing.expectEqual(@as(?u32, 0), select(&with_condensed, .bold, 75));
    try testing.expectEqual(@as(?u32, 3), select(&with_condensed, .regular, 87));
    // No normal-width bold: the normal-width regular, not the condensed bold.
    try testing.expectEqual(@as(?u32, 1), select(with_condensed[0..2], .bold, 100));
}

test "weightClass rounds to the nearest hundred" {
    // Goal: the warning threshold. DejaVu Sans Book is 400 and Bold 700; a
    // face at 600 answering a bold request is a different class and warns.
    const testing = std.testing;
    try testing.expectEqual(@as(u16, 400), weightClass(400));
    try testing.expectEqual(@as(u16, 400), weightClass(449));
    try testing.expectEqual(@as(u16, 500), weightClass(450));
    try testing.expectEqual(@as(u16, 600), weightClass(600));
    try testing.expect(weightClass(600) != @as(FontVariant, .bold).weight().cssWeight());
}
